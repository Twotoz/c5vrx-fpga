/* Triversity C5 firmware: the C5's side of the FPGA link (fpga_link.h).
 * Same firmware on all three C5s; only C5 A has the buttons wired.
 *   - UART RX on D10 (inverted): channel, gain model, AFC and calibration
 *     requests from the FPGA's menu, queued to the control task.
 *   - Buttons on D9 (UP), D8 (SELECT), D7 (DOWN), to GND with internal
 *     pull-ups, forwarded to the FPGA as markers.
 *   - Markers on the IQ pads: a button at once, one status value every
 *     250 ms (gain, C/N, flags, channel, signal, menu, gain setting: each
 *     about every 1.75 s).
 *   - The FPGA menu's settings ('S', 'T'), kept in NVS and sent back (marker
 *     7) so the menu starts as it was left.
 *   - The boot window (sampling-phase alignment) and the busy state of a
 *     calibration, which used to be the C5VRX splash and status screens. */
#include "receiver.h"
#include "fpga_link.h"
#include "cn_estimate.h"
#include <stdio.h>
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LINK_UART      UART_NUM_1
#define LINK_RX_GPIO   10
#define BTN_UP_GPIO    9
#define BTN_SELECT_GPIO 8
#define BTN_DOWN_GPIO  12
#define TICK_MS        10u
#define DEBOUNCE_TICKS 3u
#define LONG_TICKS     60u     /* 0.6 s */
#define STATUS_TICKS   25u     /* 250 ms per status value */

/* ---- boot window and busy state -------------------------------------- */
static volatile int64_t s_boot_until;
static volatile bool s_busy;
void boot_window_begin(uint32_t ms) { s_boot_until = esp_timer_get_time() + (int64_t)ms * 1000; }
void boot_window_end(void) { s_boot_until = 0; }
bool boot_window_active(void) { return s_boot_until && esp_timer_get_time() < s_boot_until; }
bool status_busy(void) { return s_busy; }
void status_note(const char *title, const char *line1, const char *line2, int percent)
{
    s_busy = true;
    if (percent >= 0) printf("STATUS_NOTE %s | %s | %s | %d%%\n", title, line1, line2, percent);
    else printf("STATUS_NOTE %s | %s | %s\n", title, line1, line2);
}
void status_note_end(void) { s_busy = false; }

/* ---- the FPGA menu's settings (fpga_link.h 'S', 'T', marker 7) ------- */
static fpga_menu_t s_menu;               /* stored (version != 0) */
static uint8_t s_menu_rx_s, s_menu_rx_t;
static bool s_menu_have_s, s_menu_have_t;
static int64_t s_menu_changed_at;
static uint32_t s_menu_stores;
static void menu_load(void)
{
    fpga_menu_t m;
    if (blob_load("fpga_menu", &m, sizeof m) && m.version == FPGA_MENU_VERSION && m.t <= 7u) s_menu = m;
}
static void menu_rx(bool is_t, uint8_t v)
{
    uint8_t *dst = is_t ? &s_menu_rx_t : &s_menu_rx_s;
    bool *have = is_t ? &s_menu_have_t : &s_menu_have_s;
    if (!*have || *dst != v) s_menu_changed_at = esp_timer_get_time();
    *dst = v;
    *have = true;
}
static void menu_poll(void)
{
    if (!fpga_menu_should_store(s_menu_have_s, s_menu_have_t, s_menu_rx_s, s_menu_rx_t, s_menu.version != 0,
                                s_menu.s, s_menu.t, esp_timer_get_time() - s_menu_changed_at))
        return;
    const fpga_menu_t m = {FPGA_MENU_VERSION, s_menu_rx_s, s_menu_rx_t};
    if (blob_store("fpga_menu", &m, sizeof m)) {
        s_menu = m;
        ++s_menu_stores;
        printf("FPGA_MENU stored s=0x%02x t=%u\n", m.s, m.t);
    }
}

/* ---- markers --------------------------------------------------------- */
static portMUX_TYPE s_mark_mux = portMUX_INITIALIZER_UNLOCKED;
static uint32_t s_marks;
static void send_mark(unsigned type, unsigned value)
{
    if (!transport_live()) return;
    uint8_t w[FPGA_MARK_WORDS];
    fpga_mark_words(type, value, w);
    /* ~12 us with interrupts off; the RX clock and this C5's own capture keep
     * running (its observers see 480 marker samples, negligible). */
    portENTER_CRITICAL(&s_mark_mux);
    rf_marker_begin();
    for (unsigned k = 0; k < FPGA_MARK_WORDS; ++k) {
        rf_marker_word(w[k]);
        esp_rom_delay_us(FPGA_MARK_WORD_US);
    }
    rf_marker_end();
    portEXIT_CRITICAL(&s_mark_mux);
    ++s_marks;
}

static unsigned status_value(unsigned type)
{
    switch (type) {
    case FPGA_MARK_GAIN: return rf_native_agc() ? 0u : s_current_gain;
    case FPGA_MARK_CN: {
        const int cn = receiver_obs_cn_x10();
        if (cn == CN_UNKNOWN_X10) return 0u;
        const int v = cn + 1000;
        return v < 1 ? 1u : v > 4095 ? 4095u : (unsigned)v;
    }
    case FPGA_MARK_FLAGS: {
        const int64_t video_at = s_last_video_us;
        char buf[8];
        return (s_afc_locked ? 1u : 0u) | (video_at && esp_timer_get_time() - video_at < 500000 ? 2u : 0u) |
               (s_busy || calibration_in_startup() ? 4u : 0u) |
               (!rf_native_agc() && calibration_dc_needed(buf, sizeof buf) ? 8u : 0u) | ((rf_lane() & 3u) << 4) |
               (s_detected_std_valid && s_detected_std == VIDEO_STD_PAL ? 64u : 0u) |
               (rf_native_agc() ? FPGA_FLAG_NATIVE : 0u);
    }
    case FPGA_MARK_CHANNEL: return (unsigned)rf_channel_index();
    case FPGA_MARK_SIGNAL: return (unsigned)(s_signal_strength < 0 ? 0 : s_signal_strength);
    case FPGA_MARK_MENU: return fpga_menu_marker(s_menu.version != 0, s_menu.s, s_menu.t);
    case FPGA_MARK_GAINSET: {
        const uint8_t gm = receiver_gain_mode();
        const unsigned code = rf_native_agc() ? 3u : gm == GAIN_MODE_LEVEL ? 0u : gm == GAIN_MODE_ULTRA ? 1u :
                              gm == GAIN_MODE_RSSI ? 2u : 3u;
        return fpga_gainset_value(code, s_afc_enabled);
    }
    default: return 0u;
    }
}

/* ---- UART link ------------------------------------------------------- */
static bool s_link_ok;
static uint32_t s_frames;
static uint8_t s_seq_f = 0xff, s_seq_b = 0xff;   /* first frame only arms */
static int64_t s_last_channel_cmd;
static void queue(int command)
{
    if (s_commands) (void)xQueueSend(s_commands, &command, 0);
}

static void link_frame(const fpga_link_frame_t *f)
{
    ++s_frames;
    const int64_t now = esp_timer_get_time();
    switch (f->tag) {
    case 'C':
        if (f->value < FPV_CHANNELS && f->value != rf_channel_index() && now - s_last_channel_cmd > 300000) {
            s_last_channel_cmd = now;
            queue(CMD_SET_CHANNEL + f->value);
        }
        break;
    case 'G': {
        static const uint8_t modes[6] = {GAIN_MODE_LEVEL, GAIN_MODE_LEVEL, GAIN_MODE_RSSI, 0, 0, GAIN_MODE_ULTRA};   /* 1 (KEEL, retired): LEVEL */
        switch (fpga_link_gain_action(f->value, rf_native_agc())) {
        case FPGA_GAIN_TO_NATIVE: queue(CMD_AGC_OWNER + 1); break;
        case FPGA_GAIN_TO_DIRECT: queue(CMD_AGC_OWNER); break;
        case FPGA_GAIN_POLICY:
            if (receiver_gain_mode() != modes[f->value]) queue(CMD_GAIN_MODE + modes[f->value]);
            break;
        default: break;
        }
        break;
    }
    case 'A':
        if (f->value < 2u && (bool)f->value != s_afc_enabled) queue(CMD_AFC + f->value);
        break;
    case 'F':
        if (s_seq_f != 0xff && f->value != s_seq_f) queue(CMD_CAL_QUICK);
        s_seq_f = f->value;
        break;
    case 'B':
        if (s_seq_b != 0xff && f->value != s_seq_b) queue(CMD_CAL_FULL);
        s_seq_b = f->value;
        break;
    case 'S': menu_rx(false, f->value); break;
    case 'T': menu_rx(true, f->value); break;
    default: break;
    }
}

static void link_start(void)
{
    const uart_config_t cfg = {
        .baud_rate = 115200, .data_bits = UART_DATA_8_BITS, .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1, .flow_ctrl = UART_HW_FLOWCTRL_DISABLE, .source_clk = UART_SCLK_DEFAULT,
    };
    s_link_ok = uart_driver_install(LINK_UART, 256, 0, 0, NULL, 0) == ESP_OK &&
                uart_param_config(LINK_UART, &cfg) == ESP_OK &&
                uart_set_pin(LINK_UART, UART_PIN_NO_CHANGE, LINK_RX_GPIO, UART_PIN_NO_CHANGE,
                             UART_PIN_NO_CHANGE) == ESP_OK &&
                uart_set_line_inverse(LINK_UART, UART_SIGNAL_RXD_INV) == ESP_OK;
    /* An unconnected (or idle-low) line must not read as data. */
    gpio_set_pull_mode(LINK_RX_GPIO, GPIO_PULLDOWN_ONLY);
    printf("FPGA_LINK rx_gpio=%d inverted %s\n", LINK_RX_GPIO, s_link_ok ? "ready" : "FAILED");
}

/* ---- buttons --------------------------------------------------------- */
static const uint8_t s_btn_gpio[3] = {BTN_UP_GPIO, BTN_SELECT_GPIO, BTN_DOWN_GPIO};
static const uint8_t s_btn_bit[3] = {FPGA_BTN_UP, FPGA_BTN_SELECT, FPGA_BTN_DOWN};
static uint32_t s_presses;

static void buttons_start(void)
{
    const gpio_config_t cfg = {
        .pin_bit_mask = (1ULL << BTN_UP_GPIO) | (1ULL << BTN_SELECT_GPIO) | (1ULL << BTN_DOWN_GPIO),
        .mode = GPIO_MODE_INPUT, .pull_up_en = GPIO_PULLUP_ENABLE, .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    (void)gpio_config(&cfg);
}

/* Short press: event on release; held LONG_TICKS: one long-press event. */
static void buttons_poll(void)
{
    static uint16_t held[3];
    static bool long_sent[3];
    for (unsigned k = 0; k < 3u; ++k) {
        if (gpio_get_level(s_btn_gpio[k]) == 0) {
            if (held[k] < 0xffffu) ++held[k];
            if (held[k] == LONG_TICKS) {
                long_sent[k] = true;
                send_mark(FPGA_MARK_BUTTON, s_btn_bit[k] | FPGA_BTN_LONG);
                ++s_presses;
            }
        } else {
            if (held[k] >= DEBOUNCE_TICKS && !long_sent[k]) {
                send_mark(FPGA_MARK_BUTTON, s_btn_bit[k]);
                ++s_presses;
            }
            held[k] = 0;
            long_sent[k] = false;
        }
    }
}

static void link_task(void *arg)
{
    (void)arg;
    fpga_link_t parser = {0};
    unsigned tick = 0, type = FPGA_MARK_GAIN;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(TICK_MS));
        if (s_link_ok) {
            uint8_t buf[32];
            const int n = uart_read_bytes(LINK_UART, buf, sizeof buf, 0);
            for (int k = 0; k < n; ++k) {
                fpga_link_frame_t f;
                if (fpga_link_feed(&parser, buf[k], &f)) link_frame(&f);
            }
        }
        buttons_poll();
        menu_poll();
        if (++tick >= STATUS_TICKS) {
            tick = 0;
            send_mark(type, status_value(type));
            type = type >= FPGA_MARK_GAINSET ? FPGA_MARK_GAIN : type + 1u;
        }
    }
}

void fpga_link_start(void)
{
    menu_load();
    link_start();
    buttons_start();
    xTaskCreate(link_task, "fpga_link", 3072, NULL, 2, NULL);
}

void fpga_link_print(void)
{
    printf("FPGA_LINK link=%u frames=%lu markers=%lu presses=%lu buttons=%u%u%u (UP SELECT DOWN, 0 = pressed)\n",
           s_link_ok, (unsigned long)s_frames, (unsigned long)s_marks, (unsigned long)s_presses,
           gpio_get_level(BTN_UP_GPIO), gpio_get_level(BTN_SELECT_GPIO), gpio_get_level(BTN_DOWN_GPIO));
    printf("FPGA_MENU stored=%u s=0x%02x t=%u stores=%lu rx_s=%d rx_t=%d\n", s_menu.version != 0, s_menu.s, s_menu.t,
           (unsigned long)s_menu_stores, s_menu_have_s ? s_menu_rx_s : -1, s_menu_have_t ? s_menu_rx_t : -1);
}
