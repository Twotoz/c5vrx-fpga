/* Triversity C5 firmware: one of three XIAO ESP32-C5 receivers feeding the
 * FPGA (https://github.com/Twotoz/c5vrx-fpga). Adapted from C5VRX-5 by Twotoz
 * and the C5VRX contributors (https://github.com/Twotoz/C5VRX,
 * https://twotoz.github.io/C5VRX/). The same firmware runs on all three. */
#include "receiver.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_app_desc.h"
#include "esp_timer.h"
#include "rf.h"
#include "phy.h"

volatile const char *s_boot_stage = "start";
static int64_t s_boot_radio_ms = -1, s_boot_ready_ms = -1;
void firmware_boot_timing(int64_t *radio_ms, int64_t *ready_ms)
{
    *radio_ms = s_boot_radio_ms; *ready_ms = s_boot_ready_ms;
}

/* The boot window: Direct Gain makes its first decision and the bounded
 * sampling-phase alignment runs (calibration_sphase.c). In C5VRX this was the
 * splash screen; here nothing is shown, the window just ends early once the
 * gain held. */
#define BOOT_WINDOW_MIN_MS 1500
#define BOOT_WINDOW_MAX_MS 3000

void app_main(void)
{
    const int64_t app_t0 = esp_timer_get_time();
    /* USB output never blocks a task when no host is attached. */
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    fcntl(fileno(stdout), F_SETFL, fcntl(fileno(stdout), F_GETFL, 0) | O_NONBLOCK);
    usb_serial_jtag_vfs_use_nonblocking();
    /* The console first: flashing (download key) and diagnostics must stay
     * reachable whatever a later boot step does. */
    console_start();
    firmware_print();
    if (!control_prepare()) {
        s_boot_stage = "control_memory";
        printf("CONTROL stack reservation failed; USB status/download remain available\n");
        return;
    }
    if (!receiver_prepare()) {
        s_boot_stage = "receiver_memory";
        printf("RECEIVER memory reservation failed; USB status/download remain available\n");
        return;
    }
    s_boot_stage = "rf";
    ESP_ERROR_CHECK(rf_start());
    s_boot_radio_ms = (esp_timer_get_time() - app_t0) / 1000;
    printf("BOOT_TIMING radio_ms=%lld\n", s_boot_radio_ms);
    s_boot_stage = "settings";
    settings_load();
    s_boot_stage = "flightlog";
    flightlog_start();
    receiver_set_gain(arc_gain_highest_rf_stage_start(rf_gain_table()));
    s_boot_stage = "calibration";
    calibration_start();
    profile_load();
    profile_boot();
    {   /* Choices of the last session (settings prefs). */
        settings_prefs_t p;
        if (settings_prefs_load(&p)) {
            if (p.dfilt_mode != PHY_DFILT_MODE_DEFAULT && !phy_dfilt_select(p.dfilt_mode))
                printf("PREFS dfilt=%u not applied; mode %d\n", p.dfilt_mode, phy_dfilt_mode());
            if (receiver_gain_mode_auto(p.gain_mode) && p.gain_mode != GAIN_MODE_DEFAULT)
                receiver_set_gain_mode(p.gain_mode, false);
            profile_select_restore(p.filter_select);
            printf("PREFS restored filter_select=%d gain_mode=%u dfilt=%d\n", p.filter_select, receiver_gain_mode(),
                   phy_dfilt_mode());
        }
    }
    s_boot_stage = "transport";
    if (transport_start() != ESP_OK) {
        s_boot_stage = "transport_fault";
        printf("TRANSPORT boot failed: no IQ; USB status/download remain available\n");
        return;
    }
    s_boot_stage = "tasks";
    const uint32_t holds = s_gain.holds;
    boot_window_begin(BOOT_WINDOW_MAX_MS);
    if (!receiver_start()) {
        boot_window_end();
        s_boot_stage = "receiver_fault";
        printf("RECEIVER start failed; USB status/download remain available\n");
        return;
    }
    control_start();
    fpga_link_start();
    /* Close the boot window once the gain held (at least the minimum), or at
     * the maximum: the startup phase alignment is bounded by it. */
    while (boot_window_active()) {
        vTaskDelay(pdMS_TO_TICKS(50));
        const int64_t ms = (esp_timer_get_time() - app_t0) / 1000;
        if (ms >= BOOT_WINDOW_MIN_MS && s_gain.state == DG_HOLD && s_gain.holds != holds) break;
    }
    boot_window_end();
    s_boot_stage = "ready";
    s_boot_ready_ms = (esp_timer_get_time() - app_t0) / 1000;
    char gain_name[16];
    printf("BOOT_TIMING ready_ms=%lld\n", s_boot_ready_ms);
    printf("TRIVERSITY C5 %s ready: %s %u MHz, gain %s ('h' for keys) fw=%s\n", esp_app_get_description()->version,
           rf_channel()->name, rf_frequency_mhz(), receiver_gain_mode_name(receiver_gain_mode(), gain_name, sizeof(gain_name)),
           firmware_id());
}
