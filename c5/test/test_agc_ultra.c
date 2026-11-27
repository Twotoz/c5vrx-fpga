/* Triversity: the experimental ULTRA gain model (agc.h): per-window decisions,
 * deadband, fold drop, and no second correction on a window from before a write. */
#include <assert.h>
#include <stdio.h>
#include "agc.h"

static agc_rssi_t a;

/* the row ULTRA's rows put nearest to `want` dB under the top */
static int rel_db(uint8_t row) { return a.rel_q8[row] / 256; }

int main(void)
{
    int16_t gain[DG_STATES];
    for (unsigned i = 0; i < DG_STATES; ++i) gain[i] = (int16_t)(i * 256);   /* 1 dB a row */
    agc_rssi_reset(&a, gain, 83);
    assert(a.homes);
    uint8_t g = a.home[a.homes / 2];
    uint64_t t = 1000000, last = 0;
    /* At the target (20 cells^2) nothing moves, also within 1.5 dB. */
    for (unsigned k = 0; k < 50; ++k) {
        const dg_observation_t o = {.pwr_x16 = (uint16_t)(k % 2 ? 20 * 16 * 13 / 10 : 20 * 16 * 8 / 10), .observed_us = t += 200};
        assert(agc_ultra_tick(&a, &o, g, t, last) == g);
    }
    /* A 12 dB dip: the next fresh window raises the gain by about 12 dB at once. */
    const dg_observation_t dip = {.pwr_x16 = 20 * 16 / 16, .observed_us = t += 200};
    const uint8_t up = agc_ultra_tick(&a, &dip, g, t, last);
    assert(up > g && rel_db(up) - rel_db(g) >= 8 && rel_db(up) - rel_db(g) <= 16);
    /* A window within ULTRA_SETTLE_US of that write is not corrected again. */
    last = t;
    const dg_observation_t stale = {.pwr_x16 = 20 * 16 / 16, .observed_us = t + ULTRA_SETTLE_US - 100};
    assert(agc_ultra_tick(&a, &stale, up, stale.observed_us, last) == up);
    /* A fold drops 6 dB on the first fresh window. */
    t = last + ULTRA_SETTLE_US + 50;
    const dg_observation_t fold = {.pwr_x16 = 20 * 16, .rails = 15, .clip_pm = 300, .observed_us = t};
    const uint8_t down = agc_ultra_tick(&a, &fold, up, t, last);
    assert(down < up && rel_db(up) - rel_db(down) >= 3 && rel_db(up) - rel_db(down) <= 9);
    /* Noise only (well below the target) climbs to the top home, never past it. */
    uint8_t n = a.home[a.homes - 1];                  /* homes run from the top row down */
    for (unsigned k = 0; k < 40; ++k) {
        t += 1000; last = t - 1000;
        const dg_observation_t o = {.pwr_x16 = 2 * 16, .observed_us = t};
        n = agc_ultra_tick(&a, &o, n, t, last);
    }
    assert(n == a.home[0]);
    printf("agc ultra: per-window steps, deadband, settle skip, fold drop, noise climb PASS (homes %u)\n", a.homes);
    return 0;
}
