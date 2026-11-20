/* Triversity C5 firmware, adapted from C5VRX-5 main/transport.c by Twotoz and
 * the C5VRX contributors (https://github.com/Twotoz/C5VRX).
 *
 * Receive-only transport: MODEM_DIAG -> PARLIO RX 40 MS/s -> 32 KiB cyclic
 * raw ring. The ring feeds this C5's own observers (gain, DC servo, AFC,
 * calibration); the FPGA takes the same IQ straight from the pads, sampled on
 * the PARLIO RX clock exported on D0. No PARLIO TX, no BitScrambler, no DAC:
 * the FPGA demodulates. The RX GDMA ring runs with interrupts off and cleared
 * suc_eof (espressif/esp-idf#19091), so no DMA boundary is a stream boundary;
 * the CPU never paces samples. */
#include "receiver.h"
#include <string.h>
#include <stdlib.h>
#include <stddef.h>
#include "driver/parlio_rx.h"
#include "esp_attr.h"
#include "esp_cache.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hal/misc.h"
#include "hal/parlio_ll.h"
#include "snapshot.h"
#include "control_window.h"
#include "phy.h"
#include "soc/ahb_dma_struct.h"
#include "soc/parl_io_struct.h"
#include "soc/pcr_struct.h"

DMA_ATTR __attribute__((aligned(64))) uint8_t s_raw_ring[RAW_RING_BYTES];
static parlio_rx_unit_handle_t s_rx;
static parlio_rx_delimiter_handle_t s_rx_delimiter;
static bool s_rx_enabled, s_started, s_transport_fault;
int s_rx_dma_ch = -1;
ring_node_t s_rx_nodes[MAX_RING_DESCRIPTORS];
int s_rx_node_count;
static uint32_t s_rx_overflow, s_dma_faults;
static struct {
    uint32_t calls, not_ready, source_invalid, pointer_invalid, lapped, timed_out;
    uint32_t max_us, max_advance;
} s_control_copy;

void sync_dma_c2m(const void *addr, size_t size)
{
    if (!addr || !size) return;
    uint32_t start = (uint32_t)addr & ~63u, end = ((uint32_t)addr + size + 63u) & ~63u;
    (void)esp_cache_msync((void *)start, end - start,
                          ESP_CACHE_MSYNC_FLAG_DIR_C2M | ESP_CACHE_MSYNC_FLAG_UNALIGNED);
}

void sync_dma_m2c(const void *addr, size_t size)
{
    if (!addr || !size) return;
    uint32_t start = (uint32_t)addr & ~63u, end = ((uint32_t)addr + size + 63u) & ~63u;
    (void)esp_cache_msync((void *)start, end - start,
                          ESP_CACHE_MSYNC_FLAG_DIR_M2C | ESP_CACHE_MSYNC_FLAG_UNALIGNED);
}

static esp_err_t prepare_rx(void)
{
    const parlio_rx_unit_config_t cfg = {
        .trans_queue_depth = 1u,
        .max_recv_size = sizeof(s_raw_ring),
        .dma_burst_size = 32u,
        .data_width = 8u,
        .clk_src = PARLIO_CLK_SRC_DEFAULT,
        .exp_clk_freq_hz = IQ_RATE_HZ,
        .clk_in_gpio_num = -1,
        /* The 40 MHz sample clock for the FPGA (D0). It is the clock this
         * receiver samples its own IQ with, so the sampling-phase alignment
         * (calibration_sphase.c) moves the FPGA's sample point too. */
        .clk_out_gpio_num = RF_RX_CLK_GPIO,
        .valid_gpio_num = -1,
        .data_gpio_nums = RF_IQ_GPIO_NUMS,
        .flags = {.free_clk = true, .clk_gate_en = false, .allow_pd = false},
    };
    esp_err_t err = parlio_new_rx_unit(&cfg, &s_rx);
    if (err != ESP_OK) return err;
    const parlio_rx_soft_delimiter_config_t delim = {
        .sample_edge = PARLIO_SAMPLE_EDGE_POS,
        .bit_pack_order = PARLIO_BIT_PACK_ORDER_LSB,
        .eof_data_len = sizeof(s_raw_ring),
        .timeout_ticks = 0u,
    };
    err = parlio_new_rx_soft_delimiter(&delim, &s_rx_delimiter);
    if (err != ESP_OK) return err;
    err = parlio_rx_unit_enable(s_rx, false);
    if (err == ESP_OK) s_rx_enabled = true;
    return err;
}

static esp_err_t start_rx(void)
{
    esp_err_t err = parlio_rx_soft_delimiter_start_stop(s_rx, s_rx_delimiter, true);
    if (err != ESP_OK) return err;
    const parlio_receive_config_t cfg = {
        .delimiter = s_rx_delimiter,
        .flags = {.partial_rx_en = true, .indirect_mount = false},
    };
    return parlio_rx_unit_receive(s_rx, s_raw_ring, sizeof(s_raw_ring), &cfg);
}

static int find_rx_dma(void)
{
    for (int k = 0; k < 3; ++k)
        if (AHB_DMA.channel[k].in.in_peri_sel.peri_in_sel_chn == 9) return k;
    return -1;
}

/* Clear suc_eof on every ring descriptor: the ring becomes endless. */
static int clear_eof(int ch)
{
    if (ch < 0 || ch >= 3) return 0;
    uint32_t first = AHB_DMA.channel[ch].in.in_dscr_bf0.val;
    if (first < 0x40800000u || first >= 0x40860000u) return 0;
    dma_descriptor_t *d = (dma_descriptor_t *)(uintptr_t)first;
    int count = 0;
    while (d && count < MAX_RING_DESCRIPTORS) {
        d->dw0.suc_eof = 0;
        sync_dma_c2m(d, sizeof(*d));
        s_rx_nodes[count].dscr = d;
        s_rx_nodes[count].buffer = (uint8_t *)d->buffer;
        s_rx_nodes[count].length = d->dw0.size ? d->dw0.size : CONTROL_BYTES;
        d = d->next;
        ++count;
        if ((uintptr_t)d == first) break;
    }
    s_rx_node_count = count;
    __asm__ __volatile__("fence rw, rw" ::: "memory");
    return count;
}

static void quiet_interrupts(void)
{
    for (int k = 0; k < 3; ++k) AHB_DMA.in_intr[k].ena.val = 0;
    PARL_IO.int_ena.val = 0;
    /* External-enable EOF selection: soft-delimiter RX never stalls on EOF. */
    PARL_IO.rx_genrl_cfg.rx_eof_gen_sel = 1;
}

static esp_err_t start_ring(void)
{
    esp_err_t err = start_rx();
    if (err != ESP_OK) return err;
    quiet_interrupts();
    s_rx_dma_ch = find_rx_dma();
    if (s_rx_dma_ch < 0) return ESP_ERR_NOT_FOUND;
    if (clear_eof(s_rx_dma_ch) < 3) return ESP_ERR_INVALID_STATE;
    PARL_IO.int_clr.val = UINT32_MAX;
    AHB_DMA.in_intr[s_rx_dma_ch].clr.val = UINT32_MAX;
    return ESP_OK;
}

esp_err_t transport_start(void)
{
    memset(s_raw_ring, 0, sizeof(s_raw_ring));
    sync_dma_c2m(s_raw_ring, sizeof(s_raw_ring));
    esp_err_t err = prepare_rx();
    if (err == ESP_OK) err = start_ring();
    if (err != ESP_OK) {
        s_transport_fault = true;
        s_rx_node_count = 0;   /* observers cannot consume a stopped ring */
        printf("TRANSPORT start failed: %s\n", esp_err_to_name(err));
        return err;
    }
    s_started = true;
    printf("TRANSPORT rx=40MS/s ring=%u descriptors=%d clk_out_gpio=%d\n", (unsigned)sizeof(s_raw_ring),
           s_rx_node_count, RF_RX_CLK_GPIO);
    return ESP_OK;
}

bool transport_live(void) { return s_started && !s_transport_fault; }
bool transport_faulted(void) { return s_transport_fault; }

void transport_poll_faults(void)
{
    if (PARL_IO.int_raw.rx_fifo_wovf_int_raw) { ++s_rx_overflow; PARL_IO.int_clr.rx_fifo_wovf_int_clr = 1; }
    if (s_rx_dma_ch >= 0) {
        uint32_t raw = AHB_DMA.in_intr[s_rx_dma_ch].raw.val & 0xfcu;
        if (raw) { ++s_dma_faults; AHB_DMA.in_intr[s_rx_dma_ch].clr.val = raw; }
    }
}

uint32_t transport_fault_count(void) { return s_rx_overflow + s_dma_faults; }

void transport_print(void)
{
    printf("TRANSPORT live=%u fault=%u rx_descriptors=%d rx_overflow=%lu dma_faults=%lu clk_out_gpio=%d\n",
           transport_live(), s_transport_fault, s_rx_node_count, (unsigned long)s_rx_overflow,
           (unsigned long)s_dma_faults, RF_RX_CLK_GPIO);
    printf("CONTROL_COPY calls=%lu not_ready=%lu source_invalid=%lu pointer_invalid=%lu "
           "lapped=%lu timed_out=%lu max_us=%lu max_advance=%lu\n",
           (unsigned long)s_control_copy.calls, (unsigned long)s_control_copy.not_ready,
           (unsigned long)s_control_copy.source_invalid, (unsigned long)s_control_copy.pointer_invalid,
           (unsigned long)s_control_copy.lapped, (unsigned long)s_control_copy.timed_out,
           (unsigned long)s_control_copy.max_us, (unsigned long)s_control_copy.max_advance);
}

int ring_node_index(uint32_t addr)
{
    for (int k = 0; k < s_rx_node_count; ++k)
        if ((uintptr_t)s_rx_nodes[k].dscr == addr) return k;
    return -1;
}

static uint32_t rx_active_addr(void) { return AHB_DMA.channel[s_rx_dma_ch].in.in_dscr_bf0.val; }

static bool completed_plan(int active, size_t need, control_copy_plan_t *out)
{
    if (active < 0 || s_rx_node_count > MAX_RING_DESCRIPTORS) return false;
    size_t lengths[MAX_RING_DESCRIPTORS];
    for (int k = 0; k < s_rx_node_count; ++k) lengths[k] = s_rx_nodes[k].length;
    return control_copy_plan(lengths, (unsigned)s_rx_node_count, (unsigned)active, need, out);
}


/* The newest completed descriptor, copied and proven not lapped. */
bool copy_control_window(uint8_t *dst, size_t bytes)
{
    ++s_control_copy.calls;
    if (s_rx_dma_ch < 0 || s_rx_node_count < 3) { ++s_control_copy.not_ready; return false; }
    /* The control task (priority 3) was preempted mid-copy by the gain
     * observer (same priority, up to ~0.5 ms per window) and the sentinel
     * (4) often enough that 30-44 % of control windows failed the overrun
     * check on the board (T LADDER copy_fail, 2026-10-13). The copy itself
     * takes tens of microseconds: hold the scheduler for it. Interrupts
     * (GDMA, timers) still run. */
    vTaskSuspendAll();
    int64_t start = esp_timer_get_time();
    int active = ring_node_index(rx_active_addr());
    if (active < 0) {
        ++s_control_copy.pointer_invalid;
        (void)xTaskResumeAll();
        return false;
    }
    control_copy_plan_t plan;
    if (!completed_plan(active, bytes, &plan)) {
        ++s_control_copy.source_invalid;
        (void)xTaskResumeAll();
        return false;
    }
    uint8_t *src = s_rx_nodes[plan.index].buffer;
    if (!src || src < s_raw_ring ||
        src + bytes > s_raw_ring + sizeof(s_raw_ring)) {
        ++s_control_copy.source_invalid;
        (void)xTaskResumeAll();
        return false;
    }
    sync_dma_m2c(src, bytes);
    memcpy(dst, src, bytes);
    int after = ring_node_index(rx_active_addr());
    const int64_t took = esp_timer_get_time() - start;
    (void)xTaskResumeAll();
    if ((uint64_t)took > s_control_copy.max_us) s_control_copy.max_us = (uint32_t)took;
    int advance = after < 0 ? s_rx_node_count : (after - active + s_rx_node_count) % s_rx_node_count;
    if (after < 0) { ++s_control_copy.pointer_invalid; return false; }
    if ((uint32_t)advance > s_control_copy.max_advance) s_control_copy.max_advance = (uint32_t)advance;
    if ((unsigned)advance >= plan.distance) { ++s_control_copy.lapped; return false; }
    if (!control_copy_current(&plan, (unsigned)s_rx_node_count, (unsigned)active, (unsigned)after,
                              (uint64_t)took, IQ_RATE_HZ)) { ++s_control_copy.timed_out; return false; }
    return true;
}

/* Four separated 64-byte regions of the newest completed descriptor. */
bool copy_probe_window(uint8_t dst[PROBE_BYTES], int *node)
{
    static const size_t offset[PROBE_REGIONS] = {512u, 1536u, 2560u, 4028u};
    if (s_rx_dma_ch < 0 || s_rx_node_count < 2) return false;
    int64_t start = esp_timer_get_time();
    int active = ring_node_index(rx_active_addr());
    if (active < 0) return false;
    control_copy_plan_t plan;
    if (!completed_plan(active, CONTROL_BYTES, &plan)) return false;
    uint8_t *src = s_rx_nodes[plan.index].buffer;
    if (!src || src < s_raw_ring ||
        src + CONTROL_BYTES > s_raw_ring + sizeof(s_raw_ring)) return false;
    for (unsigned r = 0; r < PROBE_REGIONS; ++r) {
        sync_dma_m2c(src + offset[r], PROBE_REGION_BYTES);
        memcpy(dst + r * PROBE_REGION_BYTES, src + offset[r], PROBE_REGION_BYTES);
    }
    const uint64_t took = (uint64_t)(esp_timer_get_time() - start);
    const int after = ring_node_index(rx_active_addr());
    if (took > 300 || after < 0 || !control_copy_current(&plan, (unsigned)s_rx_node_count,
        (unsigned)active, (unsigned)after, took, IQ_RATE_HZ)) return false;
    if (node) *node = (int)plan.index;
    return true;
}

bool copy_sentinel_window(uint8_t dst[64])
{
    if (s_rx_dma_ch < 0 || s_rx_node_count < 3) return false;
    const int64_t start = esp_timer_get_time();
    const int active = ring_node_index(rx_active_addr());
    control_copy_plan_t plan;
    if (!completed_plan(active, 1984u + 64u, &plan)) return false;
    uint8_t *src = s_rx_nodes[plan.index].buffer;
    if (!src || src < s_raw_ring || src + 2048u > s_raw_ring + sizeof(s_raw_ring)) return false;
    sync_dma_m2c(src + 1984u, 64u);
    memcpy(dst, src + 1984u, 64u);
    const int after = ring_node_index(rx_active_addr());
    return after >= 0 && control_copy_current(&plan, (unsigned)s_rx_node_count,
        (unsigned)active, (unsigned)after, (uint64_t)(esp_timer_get_time() - start), IQ_RATE_HZ);
}

/* 8190 contiguous bytes (204.75 us) ending where the active descriptor
 * began, valid only if RX could not have reached them during the copy. */
bool copy_snapshot(uint8_t *dst)
{
    if (s_rx_dma_ch < 0 || s_rx_node_count < 4) return false;
    int64_t start = esp_timer_get_time();
    int active = ring_node_index(rx_active_addr());
    if (active < 0) return false;
    uintptr_t base = (uintptr_t)s_raw_ring, first = (uintptr_t)s_rx_nodes[0].buffer;
    if (first < base || first - base >= sizeof(s_raw_ring)) return false;
    size_t total = 0;
    for (int k = 0; k < s_rx_node_count; ++k) {
        uintptr_t a = (uintptr_t)s_rx_nodes[k].buffer;
        if (a < base || !c5v4_snapshot_segment(sizeof(s_raw_ring), first - base, total, a - base,
                                               s_rx_nodes[k].length)) return false;
        total += s_rx_nodes[k].length;
    }
    if (total != sizeof(s_raw_ring)) return false;
    size_t end = (size_t)(s_rx_nodes[active].buffer - s_raw_ring);
    c5v4_snapshot_plan_t plan;
    if (!c5v4_snapshot_plan(total, end, s_rx_nodes[active].length, C5V4_LEVEL_SAMPLE_BYTES, &plan)) return false;
    sync_dma_m2c(s_raw_ring + plan.offset, plan.first);
    memcpy(dst, s_raw_ring + plan.offset, plan.first);
    size_t rest = C5V4_LEVEL_SAMPLE_BYTES - plan.first;
    if (rest) { sync_dma_m2c(s_raw_ring, rest); memcpy(dst + plan.first, s_raw_ring, rest); }
    uint64_t elapsed = (uint64_t)(esp_timer_get_time() - start);
    int later = ring_node_index(rx_active_addr());
    if (later < 0) return false;
    size_t after = (size_t)(s_rx_nodes[later].buffer - s_raw_ring);
    return c5v4_snapshot_current(total, C5V4_LEVEL_SAMPLE_BYTES, (after + total - end) % total,
                                 s_rx_nodes[later].length, elapsed, plan.safe_bytes, IQ_RATE_HZ);
}

/* Bench frame sweep (console J): wait for the next RX descriptor boundary,
 * time it, and copy the 8190 bytes that end there. Interrupts are off only
 * while polling for the boundary (at most FRAME_SWEEP_WAIT_US), so the time
 * is the boundary's to about a microsecond; the copy runs with them on. The
 * realtime path is DMA and the BitScrambler, which do not see this. */
#define FRAME_SWEEP_WAIT_US 400
bool copy_snapshot_at_boundary(uint8_t *dst, int64_t *boundary_us)
{
    static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
    if (s_rx_dma_ch < 0 || s_rx_node_count < 4) return false;
    const int64_t limit = esp_timer_get_time() + FRAME_SWEEP_WAIT_US;
    uint32_t start, now;
    int64_t t;
    portENTER_CRITICAL(&mux);
    start = rx_active_addr();
    do {
        now = rx_active_addr();
        t = esp_timer_get_time();
    } while (now == start && t < limit);
    portEXIT_CRITICAL(&mux);
    /* copy_snapshot ends at the descriptor active when it starts (and checks
     * itself that RX did not reach the copied bytes): still the timed one. */
    if (now == start || rx_active_addr() != now) return false;
    *boundary_us = t;
    return copy_snapshot(dst);
}

/* Endpoint bytes (odd ring byte of each pair) of the newest `n` pairs. */
bool copy_recent_endpoints(uint8_t *dst, size_t n)
{
    if (s_rx_dma_ch < 0 || s_rx_node_count < 2 || 2u * n > sizeof(s_raw_ring) / 2u) return false;
    int idx = ring_node_index(rx_active_addr());
    if (idx < 0) return false;
    uint8_t *buf = s_rx_nodes[idx].buffer;
    if (buf < s_raw_ring || buf >= s_raw_ring + sizeof(s_raw_ring)) return false;
    size_t end = (size_t)(buf - s_raw_ring) & ~(size_t)1u;
    size_t pos = (end + sizeof(s_raw_ring) - 2u * n) % sizeof(s_raw_ring);
    sync_dma_m2c(s_raw_ring, sizeof(s_raw_ring));
    for (size_t k = 0; k < n; ++k) {
        dst[k] = s_raw_ring[pos + 1u];
        pos = (pos + 2u) % sizeof(s_raw_ring);
    }
    return true;
}

/* Sampling phase: holding the RX divider one count higher for ~1 us moves
 * the RX edge against the MODEM_DIAG update by a few 4.17 ns ticks
 * (zerowidth PR #3 does this on its sample clock). */
void rx_clock_slip(uint32_t us)
{
    phy_observation_changed();
    static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
    portENTER_CRITICAL(&mux);
    uint32_t div = PCR.parl_clk_rx_conf.parl_clk_rx_div_num;
    HAL_FORCE_MODIFY_U32_REG_FIELD(PCR.parl_clk_rx_conf, parl_clk_rx_div_num, div + 1u);
    esp_rom_delay_us(us);
    HAL_FORCE_MODIFY_U32_REG_FIELD(PCR.parl_clk_rx_conf, parl_clk_rx_div_num, div);
    portEXIT_CRITICAL(&mux);
}

metrics_t measure_window(const uint8_t *s, size_t n)
{
    metrics_t m = {0};
    uint16_t hist[129] = {0};
    int clip = 0, origin = 0, coherent = 0, pi = 0, pq = 0;
    for (size_t k = 0; k < n; ++k) {
        int q = (int8_t)((s[k] & 0x0fu) << 4) >> 4, i = (int8_t)(s[k] & 0xf0u) >> 4;
        if (i == -8 || i == 7 || q == -8 || q == 7) ++clip;
        int p = i * i + q * q;
        if (p <= 4) ++origin;
        if (k) {
            int dot = i * pi + q * pq, cross = q * pi - i * pq;
            if (p >= 8 && dot > 0 && (cross < 0 ? -cross : cross) <= dot) ++coherent;
        }
        ++hist[p > 128 ? 128 : p];
        pi = i; pq = q;
    }
    unsigned cumulative = 0;
    for (unsigned p = 0; p <= 128u; ++p) {
        cumulative += hist[p];
        if (cumulative >= (n + 1u) / 2u) { m.p_median = (int)p; break; }
    }
    m.q_phase = n > 1u ? coherent * 100 / (int)(n - 1u) : 0;
    m.clip_pm = n ? clip * 1000 / (int)n : 0;
    m.origin_pm = n ? origin * 1000 / (int)n : 1000;
    return m;
}
