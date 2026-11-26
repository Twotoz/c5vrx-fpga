/* Triversity C5 firmware, adapted from C5VRX-5 main/console.c by Twotoz and
 * the C5VRX contributors: USB serial console. Polled, never paces the
 * realtime path. */
#include "receiver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/queue.h"
#include "hal/usb_serial_jtag_ll.h"
#include "rf.h"
#include "snapshot.h"

extern volatile const char *s_boot_stage;

#ifndef C5VRX5_COMMIT
#define C5VRX5_COMMIT "unknown"
#endif

/* "<version>+<commit 12>": PR channels reuse one version string, so the
 * commit is what tells two pr-N builds apart in a saved log. */
const char *firmware_id(void)
{
    static char id[64];
    if (!id[0]) snprintf(id, sizeof(id), "%s+%.12s", esp_app_get_description()->version, C5VRX5_COMMIT);
    return id;
}

void firmware_print(void)
{
    const esp_app_desc_t *d = esp_app_get_description();
    char elf[65] = "";
    (void)esp_app_get_elf_sha256(elf, sizeof(elf));
    printf("FIRMWARE id=%s version=%s commit=%s elf_sha256=%s built=\"%s %s\" idf=%s cal_dump=1\n", firmware_id(), d->version,
           C5VRX5_COMMIT, elf[0] ? elf : "unknown", d->date, d->time, d->idf_ver);
    static const int iq[8] = RF_IQ_GPIO_NUMS;
    printf("PADS iq_gpio=%d,%d,%d,%d,%d,%d,%d,%d (Q0..Q3 I0..I3) rx_clk_gpio=%d link_gpio=10 buttons=9,8,12 iq_led_gpio=27\n",
           iq[0], iq[1], iq[2], iq[3], iq[4], iq[5], iq[6], iq[7], RF_RX_CLK_GPIO);
}

static void status(void)
{
    firmware_print();
    const uint8_t gm = receiver_gain_mode();
    printf("TRIVERSITY_C5 version=%s lane=%s gain_owner=%s uptime_s=%lld heap_internal=%u heap_largest=%u heap_min=%u "
           "heap_dma=%u heap_lp=%u fw=%s\n",
           esp_app_get_description()->version, rf_lane_name(rf_lane()),
           rf_native_agc() ? "native_exp" : gm == GAIN_MODE_AUTO ? "keel1" : gm == GAIN_MODE_LEVEL ? "level" : gm == GAIN_MODE_RSSI ? "rssi" : gm == GAIN_MODE_ULTRA ? "ultra" : "manual",
           esp_timer_get_time() / 1000000, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA), (unsigned)heap_caps_get_free_size(MALLOC_CAP_RTCRAM),
           firmware_id());
    control_print();
    receiver_print();
    profile_print();
    calibration_print();
    transport_print();
    fpga_link_print();
    receiver_pause_print();
}

/* 8190 contiguous IQ bytes as hex lines (tools/capture_iq_snapshot.py). */
static void snapshot(void)
{
    if (receiver_paused()) { printf("IQSNAP_REFUSED context_busy\n"); return; }
    uint8_t *raw = malloc(C5V4_LEVEL_SAMPLE_BYTES);
    if (!raw) { printf("IQSNAP_REFUSED memory\n"); return; }
    uint32_t epoch = s_gain_epoch;
    int64_t now = esp_timer_get_time();
    bool settled = now - s_last_gain_write_us >= 500 && s_gain.state != DG_SETTLE;
    if (!settled || !copy_snapshot(raw) || epoch != s_gain_epoch) {
        free(raw);
        printf("IQSNAP_REFUSED stale_or_settling\n");
        return;
    }
    uint32_t hash = 2166136261u;
    for (unsigned k = 0; k < C5V4_LEVEL_SAMPLE_BYTES; ++k) hash = (hash ^ raw[k]) * 16777619u;
    printf("IQSNAP_BEGIN bytes=%u rate_hz=%u format=Ihigh_Qlow gain=%u lane=2 freq_mhz=%u fnv1a=%08lx fw=%s\n",
           C5V4_LEVEL_SAMPLE_BYTES, IQ_RATE_HZ, s_current_gain, rf_frequency_mhz(), (unsigned long)hash, firmware_id());
    static const char hex[] = "0123456789abcdef";
    char line[513];
    for (unsigned offset = 0; offset < C5V4_LEVEL_SAMPLE_BYTES; offset += 256) {
        unsigned size = C5V4_LEVEL_SAMPLE_BYTES - offset > 256 ? 256 : C5V4_LEVEL_SAMPLE_BYTES - offset;
        for (unsigned k = 0; k < size; ++k) {
            line[2 * k] = hex[raw[offset + k] >> 4];
            line[2 * k + 1] = hex[raw[offset + k] & 15];
        }
        line[2 * size] = 0;
        printf("IQSNAP_DATA offset=%u %s\n", offset, line);
        vTaskDelay(1);
    }
    free(raw);
    printf("IQSNAP_END fnv1a=%08lx\n", (unsigned long)hash);
}

static void help(void)
{
    printf("Triversity C5 keys: T status, I IQ snapshot, C calibration data dump (read only), D range/health report,\n"
           "  M gain map, R per-second FIELD_DIAG lines on/off, Y/W/X flight log,\n"
           "  G gain model LEVEL -> KEEL -> RSSI -> MAX -> fixed (automatic models kept across reboots),\n"
           "  c next channel, b next band, a AFC on/off, d digital RX filter mode, f analog filter AUTO/NARROW/NORMAL/WIDE,\n"
           "  A live VTX profile switch on/off, Q bench gain-pair sweep,\n"
           "  F calibrate the current filter, B full RF optimisation (ground only),\n"
           "  L IQ LED on/off (Q sign copy on the user LED), ! one bench RX sampling-phase slip, ` reboot to USB download (flashing).\n"
           "  N toggle experimental native AGC ownership and reboot,\n"
           "  The FPGA sets channel, gain model, AFC and calibration over the link (fpga_link.h).\n");
}

/* The USB reader runs above every receiver task: the download key and the
 * heartbeat work however busy the CPU is (a starved console used to make
 * flashing need the BOOT button, 2026-10-11). It drains the FIFO, handles
 * the download key itself and queues the rest for the console task. */
static QueueHandle_t s_keys;

static void usb_reader_task(void *arg)
{
    (void)arg;
    for (;;) {
        for (unsigned k = 0; k < 64; ++k) {
            uint8_t c;
            if (usb_serial_jtag_ll_read_rxfifo(&c, 1) == 0) break;
            if (c == '`') rf_reboot_to_download();   /* never returns */
            (void)xQueueSend(s_keys, &c, 0);
        }
        /* Heartbeat: shows the board is alive whatever the console does. */
        static int64_t beat;
        if (esp_timer_get_time() - beat > 5000000 && !flightlog_dumping()) {
            beat = esp_timer_get_time();
            printf("HB t_s=%lld stage=%s gain=%u startup=%u busy=%u\n", beat / 1000000, s_boot_stage,
                   s_current_gain, calibration_in_startup(), status_busy());
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

static void console_task(void *arg)
{
    (void)arg;
    for (;;) {
        uint8_t c;
        while (xQueueReceive(s_keys, &c, pdMS_TO_TICKS(100)) == pdTRUE) {
            switch (c) {
            case 'T': status(); break;
            case 'I': snapshot(); break;
            case 'F': filter_request(); break;
            case 'B': filter_request_full(); break;
            case 'C': calibration_dump_request(); break;
            case 'D': diag_report(); break;
            case 'M': receiver_print_map(); break;
            case 'R': diag_toggle_stream(); break;
            case 'L': rf_set_iq_led(!rf_iq_led()); printf("IQ_LED %s (GPIO27, Q sign copy; not saved)\n", rf_iq_led() ? "ON" : "OFF"); break;
            case '!': rx_clock_slip(1); printf("SLIP bench: one RX sampling-phase slip (T SPHASE shows the new excess)\n"); break;
            case 'Y': case 'W': case 'X': flightlog_console((char)c); break;
            case 'h': case '?': help(); break;
            case 'G': case 'N': case 'Q': case 'f': case 'c': case 'b': case 'a': case 'd': case 'A': {
                int command = c;
                if (s_commands) (void)xQueueSend(s_commands, &command, 0);
                break;
            }
            default: break;
            }
        }
        diag_poll();
        /* Bank-1 watch: prints only when a layer changes (rf_bank1_check). */
        static int64_t bank1_beat;
        if (esp_timer_get_time() - bank1_beat >= 5000000 && !calibration_in_startup()) {
            bank1_beat = esp_timer_get_time();
            rf_bank1_check(false);
        }
        static int64_t status_beat;
        if (esp_timer_get_time() - status_beat >= 2000000) {
            status_beat = esp_timer_get_time();
            const int64_t video_at = s_last_video_us;
            printf("STATUS channel=%s freq=%u afc_locked=%u video=%u signal=%d owner=%s direct_gain=%u lane=%s busy=%u fw=%s\n",
                   rf_channel()->name, rf_frequency_mhz(), s_afc_locked,
                   video_at && esp_timer_get_time() - video_at < 500000, s_signal_strength, rf_native_agc() ? "native_exp" : "direct",
                   rf_native_agc() ? 0u : s_current_gain, rf_lane_name(rf_lane()), status_busy(), firmware_id());
        }
    }
}

void console_start(void)
{
    s_keys = xQueueCreate(64, 1);
    ESP_ERROR_CHECK(s_keys ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(xTaskCreate(console_task, "console", 6144, NULL, 2, NULL) == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(xTaskCreate(usb_reader_task, "usb_reader", 3072, NULL, 10, NULL) == pdPASS ? ESP_OK :
                    ESP_ERR_NO_MEM);
}
