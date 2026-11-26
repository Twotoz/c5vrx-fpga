/* C5VRX-5 by Twotoz and the C5VRX contributors: ESP32-C5 receive-only RF
 * front end. Wi-Fi/PHY tunes the channel; MODEM_DIAG streams the ADC's
 * ultrafine Q4/I4 bits {9,6,5,4} to the PARLIO RX pins. Firmware owns the
 * gain (vendor AGC disabled), the analog filter and the frequency offset. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "arc_phy.h"

/* Triversity pad map (XIAO ESP32-C5), the same on all three C5s.
 * Shared MODEM_DIAG output / PARLIO RX input order: Q bit 0..3 (bit 3 = sign),
 * then I bit 0..3. The FPGA takes the top three bits of each component from
 * the left header row; bit 0 of I and Q only loops back into this C5 (back
 * pads, nothing soldered):
 *   D0  GPIO1   PARLIO RX clock (40 MHz) to the FPGA
 *   D1  GPIO0   Q sign       D2  GPIO25  Q bit 2      D3  GPIO7   I sign
 *   D4  GPIO23  I bit 2      D5  GPIO24  I bit 1      D6  GPIO11  Q bit 1
 *   MTDO GPIO5  Q bit 0      MTCK GPIO4  I bit 0      (internal only)
 * GPIO11 (D6) carries the least important FPGA bit: LAP87 measured a late
 * edge on it (PARLIO TX, issue #256). GPIO25/GPIO7 are strapping pins: the
 * FPGA must not pull them at boot. */
#define RF_IQ_GPIO_NUMS {5, 11, 25, 0, 4, 24, 23, 7}
#define RF_RX_CLK_GPIO 1
/* The six FPGA data pads in FPGA word order, bit 5..0 = {I sign, I2, I1,
 * Q sign, Q2, Q1} (fpga/rtl/mrc3_core.v raw word). */
#define RF_FPGA_PADS {7, 23, 24, 0, 25, 11}
/* IQ LED: the Q sign bit copied by the GPIO matrix onto the XIAO user LED
 * (GPIO27, a strapping pin, driven only after boot). Half lit = IQ flowing;
 * fully on or off = IQ stopped. 80 MHz edges next to the antenna: console L
 * turns it off for a noise comparison (not saved). */
#define RF_IQ_LED_GPIO 27
void rf_set_iq_led(bool on);
bool rf_iq_led(void);

esp_err_t rf_start(void);
/* Stop the dump writer and Wi-Fi, request a USB download boot and restart,
 * so esptool can flash with --before no-reset. Never returns. */
void rf_reboot_to_download(void);

/* Firmware gain (vendor table index). True only when written under the
 * expected PHY generation. */
bool rf_native_agc(void);
void rf_request_agc(bool native);    /* save ownership and reboot if it changes */
bool rf_set_gain(uint8_t gain, uint32_t expected_generation);
void rf_force_gain(uint8_t gain);           /* caller owns the receiver */
/* Called after every gain write and PHY restore (DC hold re-assert). */
void rf_set_post_gain_hook(void (*hook)(uint8_t gain));
const arc_gain_table_t *rf_gain_table(void);
/* Rows checked against the PHY's AGC memory at the last table capture, how many
 * matched, and the first differing row (-1 none); checked = 0: not checked. */
void rf_gain_table_hw(unsigned *checked, unsigned *match, int *first_bad);
uint32_t rf_table_generation(void);
/* DC bank-1 watch: the vendor table against its boot snapshot, every AGC
 * memory row against the table, the live words. Prints a BANK1_CHECK line
 * when a layer changes, and always with print. */
void rf_bank1_check(bool print);

/* Analog receive filter. code PHY_FILTER_CALIBRATED = the chip's own
 * calibration; skirt = second stage offset; bw20 = digital filter BW20. */
typedef struct { int8_t code; uint8_t skirt; bool bw20; } rf_filter_t;
/* True only when the PHY read back the requested code/skirt and, on the
 * pinned PHY, the production digital RX mode (PHY_DFILT_MODE_DEFAULT);
 * on a failed write the PHY layer puts the calibrated bytes back, and
 * rf_filter_applied() then reports the mismatch. */
bool rf_set_filter(rf_filter_t filter);
rf_filter_t rf_filter(void);
bool rf_filter_applied(void);
static inline bool rf_filter_equal(rf_filter_t a, rf_filter_t b)
{
    return a.code == b.code && a.skirt == b.skirt && a.bw20 == b.bw20;
}

/* MODEM_DIAG IQ lane: ULTRAFINE, or FINE/COARSE under STRONG LANE (a carrier
 * that still folds on the lowest gain rows). The FPGA only uses the angle and
 * re-weights every 3.2 us, so a lane change needs nothing on its side. */
enum { RF_LANE_COARSE, RF_LANE_FINE, RF_LANE_ULTRAFINE, RF_LANES };
esp_err_t rf_set_lane(unsigned lane);
unsigned rf_lane(void);
void rf_reroute_lane(unsigned lane);   /* live, GPIO matrix only (STRONG LANE) */
/* In-band marker to the FPGA (fpga_link.c): the six FPGA data pads leave
 * MODEM_DIAG and are driven by the CPU, one six-bit word at a time; the RX
 * clock keeps running. rf_marker_end routes the current lane back. The
 * caller keeps the whole marker inside one critical section. */
void rf_marker_begin(void);
void rf_marker_word(uint8_t word6);
void rf_marker_end(void);
const char *rf_lane_name(unsigned lane);

typedef struct { const char *name; uint16_t freq_mhz; } fpv_channel_t;
enum { FPV_BAND_R, FPV_BAND_A, FPV_BAND_B, FPV_BAND_E, FPV_BAND_F, FPV_BAND_L, FPV_BANDS };
#define FPV_CHANNELS (FPV_BANDS * 8u)
const fpv_channel_t *rf_channel(void);
size_t rf_channel_index(void);
uint16_t rf_channel_freq(size_t index);
const char *rf_band_name(unsigned band);
esp_err_t rf_set_channel(size_t index);
void rf_next_band(void);
void rf_next_channel(void);
uint16_t rf_frequency_mhz(void);
/* Espressif documents C5 channel centres 5180..5885 MHz; R8, E6..E8 sit
 * above that (tuned with phy_set_freq) and are not characterised. */
#define RF_SPEC_MIN_MHZ 5180u
#define RF_SPEC_MAX_MHZ 5885u
static inline bool rf_freq_in_spec(uint16_t mhz) { return mhz >= RF_SPEC_MIN_MHZ && mhz <= RF_SPEC_MAX_MHZ; }
int rf_offset_khz(void);
void rf_set_offset_khz(int offset_khz);
