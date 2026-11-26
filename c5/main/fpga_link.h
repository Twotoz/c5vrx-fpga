/* Triversity C5 firmware: the protocol between the FPGA and the C5s (pure
 * logic, host test test/test_fpga_link.c). Extends the C5VRX channel link
 * (main/channel_link.h of the TANG9K_DUAL hardware experiment, C5VRX by
 * Twotoz and the C5VRX contributors).
 *
 * FPGA -> C5 (one UART wire to D10 of all three C5s, 115200 8N1, sent
 * inverted: the line idles low, which keeps the Tang Nano 20K's audio
 * amplifier on that pin off). A frame is four bytes:
 *     0xC5, tag, value, 0x79 ^ value ^ tag ^ 'C'
 * ('C' frames are the TANG9K_DUAL channel frames unchanged). The FPGA repeats
 * absolute settings continuously; a C5 acts when the value differs from its
 * own. One-shot requests carry a sequence number and act when it changes.
 *     'C' channel index (band * 8 + channel)           absolute
 *     'G' Direct Gain model 0 LEVEL, 1 KEEL, 2 RSSI    absolute
 *         3 Native AGC, 4 restore saved Direct Gain (reboot on ownership change)
 *     'A' AFC 0 off, 1 on                              absolute
 *     'F' calibrate the current filter (console F)     sequence number
 *     'B' full RF optimisation (console B)             sequence number
 *
 * C5 -> FPGA (in-band, on the IQ pads): the six FPGA data pads leave
 * MODEM_DIAG for a few microseconds and carry six-bit words, each held
 * FPGA_MARK_WORD_US; the RX clock keeps running. Word bits 5..0 =
 * {I sign, I2, I1, Q sign, Q2, Q1}, the FPGA's raw word. A marker is
 *     0x38, 0x07, then four payload words (0x20 | nibble, 0x10 | nibble, ...)
 * carrying 16 bits, most significant nibble first: type (4) and value (12).
 * Raw IQ never holds one word for FPGA_MARK_WORD_US (80 samples) and the
 * two preamble words in a row; the FPGA leaves this C5 out of the combination
 * while a marker runs. Types:
 *     1 BUTTON   bit 0 UP, 1 SELECT, 2 DOWN (pressed); bit 4 long press
 *     2 GAIN     Direct Gain row in use (0 if native owns gain)
 *     3 CN       C/N x10 + 1000 (clamped 0..4095; 0 unknown)
 *     4 FLAGS    bit 0 AFC locked, 1 video, 2 busy (calibration), 3 DC fault,
 *                4..5 IQ lane (0 coarse, 1 fine, 2 ultrafine), 6 PAL, 7 Native AGC applied
 *     5 CHANNEL  channel index
 *     6 SIGNAL   signal strength 0..100 */
#pragma once
#include <stdint.h>

enum { FPGA_GAIN_NATIVE = 3, FPGA_GAIN_DIRECT_RESTORE = 4, FPGA_FLAG_NATIVE = 1u << 7 };

/* Interpret a gain frame against the current owner. Keep the old 0..2
 * firmware-policy selections, while 4 rolls back without altering prefs. */
enum { FPGA_GAIN_IGNORE, FPGA_GAIN_POLICY, FPGA_GAIN_TO_NATIVE, FPGA_GAIN_TO_DIRECT };
static inline unsigned fpga_link_gain_action(uint8_t value, int native_active)
{
    if (value == FPGA_GAIN_NATIVE) return native_active ? FPGA_GAIN_IGNORE : FPGA_GAIN_TO_NATIVE;
    if (value > FPGA_GAIN_DIRECT_RESTORE) return FPGA_GAIN_IGNORE;
    if (native_active) return FPGA_GAIN_TO_DIRECT;
    return value < FPGA_GAIN_NATIVE ? FPGA_GAIN_POLICY : FPGA_GAIN_IGNORE;
}

#define FPGA_LINK_SYNC 0xC5u
#define FPGA_LINK_KEY  0x79u
#define FPGA_LINK_BASE 0x43u   /* 'C' */

typedef struct { uint8_t state, tag, value; } fpga_link_t;
typedef struct { uint8_t tag, value; } fpga_link_frame_t;

static inline uint8_t fpga_link_check(uint8_t tag, uint8_t value)
{
    return (uint8_t)(FPGA_LINK_KEY ^ value ^ tag ^ FPGA_LINK_BASE);
}

static inline int fpga_link_known(uint8_t tag)
{
    return tag == 'C' || tag == 'G' || tag == 'A' || tag == 'F' || tag == 'B';
}

/* Feed one byte; returns 1 and fills *out on a complete valid frame, else 0.
 * Resynchronises on any error. */
static inline int fpga_link_feed(fpga_link_t *p, uint8_t b, fpga_link_frame_t *out)
{
    switch (p->state) {
    case 0: p->state = b == FPGA_LINK_SYNC ? 1u : 0u; return 0;
    case 1:
        if (fpga_link_known(b)) { p->tag = b; p->state = 2u; }
        else p->state = b == FPGA_LINK_SYNC ? 1u : 0u;
        return 0;
    case 2: p->value = b; p->state = 3u; return 0;
    default:
        p->state = b == FPGA_LINK_SYNC ? 1u : 0u;
        if (b != fpga_link_check(p->tag, p->value)) return 0;
        p->state = 0u;
        out->tag = p->tag;
        out->value = p->value;
        return 1;
    }
}

#define FPGA_MARK_WORD_US 2u
#define FPGA_MARK_WORDS 6u
#define FPGA_MARK_PRE_A 0x38u
#define FPGA_MARK_PRE_B 0x07u
enum { FPGA_MARK_BUTTON = 1, FPGA_MARK_GAIN, FPGA_MARK_CN, FPGA_MARK_FLAGS, FPGA_MARK_CHANNEL, FPGA_MARK_SIGNAL };
enum { FPGA_BTN_UP = 1, FPGA_BTN_SELECT = 2, FPGA_BTN_DOWN = 4, FPGA_BTN_LONG = 16 };

/* The six words of one marker. */
static inline void fpga_mark_words(unsigned type, unsigned value, uint8_t w[FPGA_MARK_WORDS])
{
    const unsigned payload = ((type & 15u) << 12) | (value & 0xfffu);
    w[0] = FPGA_MARK_PRE_A;
    w[1] = FPGA_MARK_PRE_B;
    for (unsigned k = 0; k < 4u; ++k)
        w[2 + k] = (uint8_t)(((k & 1u) ? 0x10u : 0x20u) | ((payload >> (12u - 4u * k)) & 15u));
}

/* FPGA-side decode of the four payload words (for the host test and as the
 * reference for the RTL): -1 when a word lacks its marker bits. */
static inline int fpga_mark_decode(const uint8_t w[4])
{
    unsigned payload = 0;
    for (unsigned k = 0; k < 4u; ++k) {
        if ((w[k] & 0x30u) != ((k & 1u) ? 0x10u : 0x20u)) return -1;
        payload = payload << 4 | (w[k] & 15u);
    }
    return (int)payload;
}
