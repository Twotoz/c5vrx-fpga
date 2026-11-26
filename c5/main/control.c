/* Triversity C5 firmware, adapted from C5VRX-5 main/control.c by Twotoz and
 * the C5VRX contributors: 50 ms control loop.
 * AFC acquisition, PAL/NTSC detection, signal strength and the commands of
 * the console and the FPGA link (channel, gain model, AFC, calibration).
 * No menu, no BOOT-button UI, no scanner (the FPGA scans by stepping the
 * channel over the link and measuring the IQ itself), no decoder or output
 * level. Observes completed RX descriptors only. */
#include "receiver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "afc_ctrl.h"
#include "profile_logic.h"
#include "cn_estimate.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "phase8_gain_lut.h"
#include "phy.h"
#include "snapshot.h"
#include "rf.h"
#include "flightlog.h"
#include "experimental.h"
#include "flightlog_format.h"

#define TICK_MS          50
#define RETUNE_SETTLE_TICKS 10          /* 500 ms after a PHY transaction */
#define CONTROL_STACK_BYTES 6144u

typedef struct {
    StaticTask_t task;
    StaticQueue_t commands;
    uint8_t command_storage[16u * sizeof(int)];
    StackType_t stack[CONTROL_STACK_BYTES/sizeof(StackType_t)] __attribute__((aligned(portBYTE_ALIGNMENT)));
} control_memory_t;
static control_memory_t *s_control_memory;

bool control_prepare(void)
{
    if(!s_control_memory) {
        s_control_memory=heap_caps_aligned_alloc(portBYTE_ALIGNMENT,sizeof(*s_control_memory),
            MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
        if(s_control_memory)memset(s_control_memory,0,sizeof(*s_control_memory));
    }
    return s_control_memory!=NULL;
}

volatile int s_signal_strength;
volatile bool s_scan_active;
volatile unsigned s_scan_progress;
volatile int s_cfo_khz;
volatile bool s_afc_locked;
volatile bool s_afc_enabled = true;
volatile std_mode_t s_std_mode = STD_MODE_AUTO;
volatile bool s_detected_std_valid;
volatile video_standard_t s_detected_std = VIDEO_STD_NTSC;
volatile int64_t s_last_video_us;
QueueHandle_t s_commands;

static uint8_t s_window[CONTROL_BYTES];
#define AFC_WINDOW_BYTES C5V4_LEVEL_SAMPLE_BYTES
static uint8_t s_afc_window[AFC_WINDOW_BYTES];
static uint8_t s_pal_votes, s_ntsc_votes;
static uint8_t s_last_std = 0xFF;      /* last stable standard (NVS) */
static unsigned s_afc_corrections, s_afc_weak_skips;
typedef struct {
    afc2_evidence_t history;
    uint64_t sampled_us, qualified_us;
    uint32_t context, qualified_gain_epoch;
    int32_t raw_porch_khz, residual_khz;
    int cn_x10;
    bool latest_valid, sticky_lock;
    const char *window, *held;
} afc_evidence_snapshot_t;
static afc_evidence_snapshot_t s_afc_evidence = {.window="boot", .held="boot", .cn_x10=CN_UNKNOWN_X10};
/* Learned offset sign (afc_ctrl.h sign check), persisted once observed. */
static volatile int8_t s_afc_sign = 1;
static volatile uint8_t s_afc_sign_state;
static bool s_afc_sign_saved;

static void standard_reset(void)
{
    s_pal_votes = s_ntsc_votes = 0;
    s_detected_std_valid = false;
}

/* Burst-confirmed standard from the AFC estimator; a few agreeing
 * windows make it stable and remembered for the next boot's menu. */
static void standard_vote(unsigned afc_standard)
{
    bool pal = afc_standard == 2u;
    if (pal) { if (s_pal_votes < 8u) ++s_pal_votes; if (s_ntsc_votes) --s_ntsc_votes; }
    else { if (s_ntsc_votes < 8u) ++s_ntsc_votes; if (s_pal_votes) --s_pal_votes; }
    if (s_pal_votes >= 3u && s_pal_votes >= s_ntsc_votes + 2u) { s_detected_std = VIDEO_STD_PAL; s_detected_std_valid = true; }
    else if (s_ntsc_votes >= 3u && s_ntsc_votes >= s_pal_votes + 2u) { s_detected_std = VIDEO_STD_NTSC; s_detected_std_valid = true; }
    if (s_detected_std_valid && s_last_std != (uint8_t)s_detected_std) {
        s_last_std = (uint8_t)s_detected_std;
        (void)blob_store("last_std", &s_last_std, 1);
    }
}

/* 0..100 from phase coherence, envelope and gain headroom. */
static int strength(const metrics_t *m, uint8_t gain)
{
    if (m->q_phase < 18 || m->origin_pm > 850) return 0;
    int coherence = (m->q_phase - 18) * 100 / 62;
    int power = ((m->p_median >> 4) - 6) * 100 / 28;   /* ultrafine lane: 4^2 */
    int max_gain = rf_gain_table()->max_index;
    int headroom = (max_gain - (int)gain) * 100 / (max_gain > 2 ? max_gain - 2 : 1);
    coherence = coherence < 0 ? 0 : coherence > 100 ? 100 : coherence;
    power = power < 0 ? 0 : power > 100 ? 100 : power;
    headroom = headroom < 0 ? 0 : headroom > 100 ? 100 : headroom;
    return (coherence * 2 + power + headroom) / 4;
}

static void after_retune(void)
{
    ++s_control_epoch;
    {
        uint8_t e[3] = {(uint8_t)rf_channel_index()};
        flog_put16(e + 1, rf_frequency_mhz());
        flightlog_event(FLOG_E_CHANNEL, e, sizeof(e));
    }
    s_cfo_khz = 0;
    s_afc_locked = false;
    standard_reset();
    settings_save();
    profile_channel_changed();   /* another channel may carry another VTX */
    printf("[CHANNEL] %s %u MHz%s\n", rf_channel()->name, rf_channel()->freq_mhz,
           rf_freq_in_spec(rf_channel()->freq_mhz) ? "" : " (above the documented C5 range, not characterised)");
}

/* AFC OFF returns the synthesizer to the exact channel centre (0 kHz offset). */
/* Menu choices kept across reboots (settings prefs). */
static void prefs_save(void)
{
    const uint8_t gain = receiver_gain_mode();
    const settings_prefs_t p = {SETTINGS_PREFS_VERSION, (int8_t)profile_selected(),
                                receiver_gain_mode_auto(gain) ? gain : (uint8_t)GAIN_MODE_DEFAULT,
                                (uint8_t)phy_dfilt_mode()};
    settings_prefs_store(&p);
}

/* Menu PHY FILT: the digital RX filter mode 12 -> 0 -> 4 -> 8 (saved;
 * phy.h). A different transfer function changes the receiver noise
 * (PR #244: +0.24..+0.73 dB between modes) and the IQ the DC servo trims,
 * so the gain observation restarts on the new mode. */
static void cycle_dfilt(void)
{
    const int want = phy_dfilt_next(phy_dfilt_mode());
    const bool ok = phy_dfilt_select(want);
    receiver_dc_reset_all();
    if (ok) prefs_save();
    printf("[DFILT] mode=%d requested=%d applied=%u hw=%d (saved; boot default %d)\n", phy_dfilt_mode(), want,
           ok, phy_dfilt_hw_mode(), PHY_DFILT_MODE_DEFAULT);
}

static void toggle_afc(void)
{
    s_afc_enabled = !s_afc_enabled;
    s_afc_locked = false;
    s_cfo_khz = 0;
    if (!s_afc_enabled && rf_offset_khz() != 0) {
        rf_set_offset_khz(0);
        s_last_gain_write_us = esp_timer_get_time();
        ++s_gain_epoch;
    }
    ++s_control_epoch;
    const uint8_t off = !s_afc_enabled;
    (void)blob_store("afc_off", &off, 1);
    printf("[AFC] mode=%s offset_khz=%d\n", s_afc_enabled ? "ON" : "OFF", rf_offset_khz());
}

static void command(int c)
{
    if (status_busy()) {   /* a calibration owns the receiver */
        if (c < CMD_SET_CHANNEL)   /* the FPGA link repeats itself: no message per frame */
            printf("COMMAND %c refused=busy (a calibration runs; retry when it ends)\n", c);
        return;
    }
    switch (c) {
    case 'G':
        if (rf_native_agc()) { puts("GAIN native (EXP); use FPGA Signal or N to restore Direct Gain"); return; }
        receiver_set_gain_mode(receiver_gain_mode_next(receiver_gain_mode()), true); prefs_save(); return;
    case 'N': rf_request_agc(!rf_native_agc()); return;
    case 'Q': if (!rf_native_agc()) receiver_pair_sweep_toggle(); return;   /* bench: the real gain step of every table row pair */
    case 'f': (void)profile_select_cycle(); prefs_save(); return;
    case 'c': rf_next_channel(); after_retune(); return;
    case 'b': rf_next_band(); after_retune(); return;
    case 'a': toggle_afc(); return;
    case 'd': cycle_dfilt(); return;
    case 'A':
        profile_set_live_mode(!profile_live_mode());
        printf("PROFILE live switch %s (saved)\n", profile_live_mode() ? "ON" : "OFF");
        return;
    default: break;
    }
    if (c >= CMD_SET_CHANNEL && c < CMD_SET_CHANNEL + (int)FPV_CHANNELS) {
        const size_t ch = (size_t)(c - CMD_SET_CHANNEL);
        if (ch != rf_channel_index() && rf_set_channel(ch) == ESP_OK) after_retune();
    } else if (c >= CMD_GAIN_MODE && c < CMD_GAIN_MODE + 256) {
        const uint8_t mode = (uint8_t)(c - CMD_GAIN_MODE);
        if (receiver_gain_mode_auto(mode) && mode != receiver_gain_mode()) {
            receiver_set_gain_mode(mode, true);
            prefs_save();
        }
    } else if (c == CMD_AFC || c == CMD_AFC + 1) {
        if ((c == CMD_AFC + 1) != s_afc_enabled) toggle_afc();
    } else if (c == CMD_AGC_OWNER || c == CMD_AGC_OWNER + 1) {
        rf_request_agc(c == CMD_AGC_OWNER + 1);
    } else if (c == CMD_CAL_QUICK) {
        filter_request();
    } else if (c == CMD_CAL_FULL) {
        filter_request_full();
    }
}

static uint32_t afc_context(void)
{
    const uint32_t parts[5] = {(uint32_t)rf_channel_index(), s_control_epoch, (uint32_t)rf_offset_khz(),
                               rf_table_generation(), phy_generation()};
    uint32_t h = 2166136261u;
    for (unsigned k = 0; k < 5u; ++k) h = (h ^ parts[k]) * 16777619u;
    return h;
}

/* End-to-end video quality, one-second periods (video_quality.h). */
static vq_acc_t s_vq_acc;
static vq_t s_vq;
static uint32_t s_vq_periods;

static bool copy_afc_window(uint8_t *dst)
{
    vTaskSuspendAll();
    const bool ok = copy_snapshot(dst);
    (void)xTaskResumeAll();
    return ok;
}

static void control_task(void *arg)
{
    (void)arg;
    afc2_ctrl_t afc = {.target_khz = AFC_PORCH_TARGET_KHZ, .sign = s_afc_sign, .sign_state = s_afc_sign_state};
    uint8_t seen_sign_state = afc.sign_state;
    bool own_write = false;
    uint8_t afc_lost = 0;
    unsigned settle = RETUNE_SETTLE_TICKS;
    bool was_locked = false;
    uint32_t seen_phy = phy_generation(), seen_control = s_control_epoch;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(TICK_MS));
        int c;
        experimental_poll();
        for (unsigned k = 0; k < 8 && xQueueReceive(s_commands, &c, 0) == pdTRUE; ++k) command(c);
        transport_poll_faults();
        if (phy_generation() != seen_phy || s_control_epoch != seen_control) {
            seen_phy = phy_generation();
            seen_control = s_control_epoch;
            s_cfo_khz = 0;
            afc2_ctrl_invalidate(&afc);
            settle = own_write ? 2u : RETUNE_SETTLE_TICKS;
        }
        uint32_t gain_epoch = s_gain_epoch, ctx = afc_context();
        if (s_scan_active) {
            afc2_ctrl_invalidate(&afc);
            memset(&s_afc_evidence, 0, sizeof(s_afc_evidence));
            s_afc_evidence.window="scan"; s_afc_evidence.held="scan";
            s_afc_evidence.cn_x10=CN_UNKNOWN_X10;
            diag_window(false, false, false);
            continue;
        }
        const bool copied = copy_control_window(s_window, CONTROL_BYTES);
        metrics_t m = {0};
        if (copied) {
            m = measure_window(s_window, CONTROL_BYTES);
            s_signal_strength = (s_signal_strength * 3 + strength(&m, rf_native_agc() ? rf_gain_table()->max_index : s_current_gain) + 2) / 4;
        }

        /* AFC: burst/line-timing-confirmed sync/porch levels, never the
         * scene-biased FM slope; acquisition only, sticky once locked. */
        if (afc2_ctrl_sync(&afc, ctx, own_write)) { s_afc_locked = false; afc_lost = 0; }
        own_write = false;
        int64_t now = esp_timer_get_time();
        /* Preserve the receiver-settling gate independently of the retired
         * kp ladder: AFC must never use samples spanning a gain/context write. */
        const bool receiver_ok = copied && settle == 0 && ctx == afc_context() && !phy_busy() &&
                                 now - s_last_gain_write_us >= 5000;
        /* The AFC window holds 3.2 lines, not the 1.6 of one descriptor:
         * without a detected burst a sync counts only with a second one a
         * line earlier, which one descriptor contains in ~43 % of windows
         * (board IQ replay 2026-10-26: 45 % vs 30/30 snapshots). It ends
         * where the active descriptor began, so it covers s_window. */
        const bool afc_copied = receiver_ok && copy_afc_window(s_afc_window);
        bool window_ok = afc_copied && afc2_envelope_stationary(s_afc_window, AFC_WINDOW_BYTES);
        const char *afc_window_reason = !copied ? "copy_missing" : settle ? "settle" :
            ctx != afc_context() ? "context" : phy_busy() ? "phy_busy" : !receiver_ok ? "gain_settle" :
            !afc_copied ? "afc_copy_missing" : !window_ok ? "nonstationary" : "measured";
        if (settle) --settle;
        afc2_result_t r = {0};
        if (window_ok) {
            r = afc2_measure(s_afc_window, AFC_WINDOW_BYTES, c5vrx_phase8_gain_lut);
            afc2_ctrl_observe_at(&afc, &r, (uint64_t)now);
            vq_add(&s_vq_acc, &r);
        } else afc2_ctrl_miss(&afc);   /* settle and context changes reset via afc2_ctrl_sync */
        if (vq_close(&s_vq_acc, now, &s_vq)) ++s_vq_periods;
        if (copied) s_cfo_khz = r.porch_pairs ? r.porch_khz : 0;
        /* Burst or line timing confirmed the syncs (afc2_measure). */
        bool valid = window_ok && r.lines && r.standard && r.porch_pairs && r.sync_pairs;
        const bool qualified=valid && r.polarity && gain_epoch==s_gain_epoch && ctx==afc_context();
        if (s_afc_evidence.context != ctx) s_afc_evidence.qualified_us=0;
        if (qualified) {
            s_afc_evidence.qualified_us=(uint64_t)now;
            s_afc_evidence.qualified_gain_epoch=gain_epoch;
            s_afc_evidence.raw_porch_khz=r.porch_khz;
            s_afc_evidence.residual_khz=r.porch_khz-afc.target_khz;
        }
        if (valid) { s_last_video_us = now; standard_vote(r.standard); profile_observe(&r); }
        if (!s_afc_enabled && rf_offset_khz() != 0) {
            rf_set_offset_khz(0);
            s_last_gain_write_us = esp_timer_get_time();
            ++s_gain_epoch;
        }
        bool was = s_afc_locked;
        if (!s_afc_enabled) { s_afc_locked = false; afc_lost = 0; }
        else if (copied) s_afc_locked = afc2_native_lock(s_afc_locked, valid, afc2_ctrl_can_lock(&afc, true), afc.n, &afc_lost);
        if (was && !s_afc_locked) afc2_ctrl_reacquire(&afc);
        /* Re-acquisition retunes only on a strong carrier: at the range edge
         * the porch estimate is pulled toward the receiver centre and would
         * walk the offset the wrong way (cn_estimate.h, afc_bias.py). A weak
         * window still feeds the estimate history, it just cannot step. */
        const int cn_x10 = receiver_obs_cn_x10();
        const char *afc_held = !s_afc_enabled ? "afc_off" : s_afc_locked ? "sticky_lock" : !valid ? "window" : "actuator";
        if (s_afc_enabled && !s_afc_locked && valid &&
            phy_try_actuator(phy_generation())) {
            int32_t step = 0;
            const bool strong = receiver_obs_cn_x10() >= AFC_MIN_CN_X10;   /* noise-referenced power C/N */
            if (afc2_ctrl_decide(&afc, gain_epoch == s_gain_epoch && strong, &step)) {
                rf_set_offset_khz(rf_offset_khz() + (int)step);
                s_last_gain_write_us = esp_timer_get_time();   /* restore re-forces gain */
                ++s_gain_epoch;
                ++s_afc_corrections;
                own_write = true;
                afc_held="stepped";
                printf("[AFC] step_khz=%ld offset_khz=%d cn_est_x10=%d coherence=%d gain=%u\n", (long)step,
                       rf_offset_khz(), cn_x10, s_obs_coherence, s_current_gain);
            } else if (!strong && afc2_ctrl_stable(&afc, &step) &&
                       (step > AFC2_CTRL_DEADBAND_KHZ || step < -AFC2_CTRL_DEADBAND_KHZ)) {
                ++s_afc_weak_skips;    /* would have stepped on a weak carrier */
            }
            if (!own_write) {
                int32_t median=0;
                afc_held=gain_epoch != s_gain_epoch ? "gain_changed" : !strong ? "weak_or_unknown_cn" :
                    afc.n<AFC2_CTRL_SAMPLES ? "collecting" : !afc2_ctrl_stable(&afc,&median) ? "unstable" :
                    (median>=-AFC2_CTRL_DEADBAND_KHZ && median<=AFC2_CTRL_DEADBAND_KHZ) ? "deadband" : "correction_budget";
            }
            phy_end_actuator();
        }
        s_afc_evidence.history=afc2_ctrl_evidence(&afc,(uint64_t)now);
        s_afc_evidence.sampled_us=(uint64_t)now;
        s_afc_evidence.context=ctx;
        s_afc_evidence.cn_x10=cn_x10;
        s_afc_evidence.latest_valid=qualified;
        s_afc_evidence.sticky_lock=s_afc_locked;
        s_afc_evidence.window=qualified ? "valid" : valid ? "stale_gain_or_context" : window_ok ? "no_confirmed_sync" : afc_window_reason;
        s_afc_evidence.held=afc_held;
        if (afc.sign_state != seen_sign_state) {
            seen_sign_state = afc.sign_state;
            s_afc_sign_state = afc.sign_state;
            printf("[AFC] offset sign %s: %+d\n", afc.sign_state == AFC2_SIGN_FLIPPED ? "FLIPPED" : "confirmed",
                   afc.sign < 0 ? -1 : 1);
            int8_t sign = afc.sign < 0 ? -1 : 1;
            if (!s_afc_sign_saved || sign != s_afc_sign) {
                s_afc_sign = sign;
                s_afc_sign_saved = blob_store("afc_sign", &sign, 1);
            }
        }
        diag_window(window_ok, valid, own_write);   /* own_write: an AFC step this window */
        if (s_afc_locked && !was_locked)
            printf("[VIDEO] locked %s %u MHz %s offset_khz=%d gain=%u\n", rf_channel()->name,
                   rf_channel()->freq_mhz, r.standard == 2 ? "PAL" : "NTSC", rf_offset_khz(), s_current_gain);
        was_locked = s_afc_locked;
    }
}

void control_start(void)
{
    if (!blob_load("last_std", &s_last_std, 1)) s_last_std = 0xFF;
    uint8_t afc_off = 0;
    if (blob_load("afc_off", &afc_off, 1)) s_afc_enabled = !afc_off;
    profile_set_live_mode(experimental_get(EXP_AUTO_PROFILE) != 0);
    experimental_log_state();
    int8_t sign;
    if (blob_load("afc_sign", &sign, 1) && (sign == 1 || sign == -1)) {
        s_afc_sign = sign;
        s_afc_sign_state = AFC2_SIGN_CONFIRMED;
        s_afc_sign_saved = true;
    }
    s_commands = xQueueCreateStatic(16, sizeof(int), s_control_memory->command_storage,
                                   &s_control_memory->commands);
    ESP_ERROR_CHECK(s_commands ? ESP_OK : ESP_ERR_NO_MEM);
    /* IDF task stack depths are bytes. Reserve before driver allocations,
     * then supply that same 6144-byte stack and TCB without another malloc. */
    ESP_ERROR_CHECK(control_prepare() &&
        xTaskCreateStatic(control_task,"control",CONTROL_STACK_BYTES,NULL,3,
            s_control_memory->stack,&s_control_memory->task)!=NULL ? ESP_OK:ESP_ERR_NO_MEM);
}

void control_flog_afc(int16_t *offset_khz, int16_t *residual_khz, uint32_t *corrections)
{
    *offset_khz = (int16_t)rf_offset_khz();
    *residual_khz = (int16_t)s_afc_evidence.residual_khz;
    *corrections = s_afc_corrections;
}

/* End-to-end video quality of the last second (video_quality.h). */
void control_video_quality(vq_t *out) { vTaskSuspendAll(); *out = s_vq; (void)xTaskResumeAll(); }

void control_print(void)
{
    vTaskSuspendAll();
    const afc_evidence_snapshot_t afc_snapshot=s_afc_evidence;
    const uint64_t afc_now=(uint64_t)esp_timer_get_time();
    const bool afc_context_current=afc_snapshot.context==afc_context();
    const bool afc_gain_current=afc_snapshot.qualified_us && afc_snapshot.qualified_gain_epoch==s_gain_epoch;
    (void)xTaskResumeAll();
    const afc2_evidence_t evidence=afc_snapshot.history;
    printf("AFC_EVIDENCE latest_valid=%u context_current=%u qualified_gain_current=%u sticky_lock=%u target_khz=%d "
           "last_qualified_raw_porch_khz=%ld last_qualified_residual_khz=%ld qualified_age_ms=%lld sample_age_ms=%lld "
           "n=%u timestamped=%u stable=%u median_residual_khz=%ld mad_khz=%ld oldest_age_ms=%lld newest_age_ms=%lld "
           "cn_x10=%d window=%s held=%s reference=porch_not_rf_truth\n",
           afc_snapshot.latest_valid, afc_context_current, afc_gain_current, afc_snapshot.sticky_lock, AFC_PORCH_TARGET_KHZ,
           (long)afc_snapshot.raw_porch_khz, (long)afc_snapshot.residual_khz,
           (long long)afc2_evidence_age_ms(afc_context_current && afc_gain_current ? afc_snapshot.qualified_us : 0,afc_now),
           (long long)afc2_evidence_age_ms(afc_snapshot.sampled_us,afc_now),
           evidence.n, evidence.timestamped, evidence.stable, (long)evidence.median_khz, (long)evidence.mad_khz,
           (long long)afc2_evidence_age_ms(evidence.oldest_us,afc_now),
           (long long)afc2_evidence_age_ms(evidence.newest_us,afc_now),
           afc_snapshot.cn_x10, afc_snapshot.window, afc_snapshot.held);
    printf("CONTROL channel=%s freq=%u offset_khz=%d cfo_khz=%d afc_locked=%u afc_corrections=%u "
           "afc_weak_skips=%u afc_sign=%+d(%s) detected=%s signal=%d deviation_x100=%d profile=%s busy=%u\n",
           rf_channel()->name, rf_frequency_mhz(), rf_offset_khz(), s_cfo_khz, s_afc_locked,
           s_afc_corrections, s_afc_weak_skips, s_afc_sign,
           s_afc_sign_state == AFC2_SIGN_FLIPPED ? "flipped" : s_afc_sign_state == AFC2_SIGN_CONFIRMED ? "confirmed" :
           "unverified", s_detected_std_valid ? (s_detected_std == VIDEO_STD_PAL ? "PAL" : "NTSC") : "none",
           s_signal_strength, profile_deviation_x100(rf_channel_index()), profile_name(profile_active()), status_busy());
    vq_t vq;
    control_video_quality(&vq);
    printf("VIDEO_Q known=%u snr_x10=%d lines_x100=%u lines=%lu windows=%lu periods=%lu (end-to-end: sync/porch "
           "spread of the demodulated video, last second)\n", vq.known, vq.snr_x10, vq.lines_x100,
           (unsigned long)vq.lines, (unsigned long)vq.windows, (unsigned long)s_vq_periods);
}
