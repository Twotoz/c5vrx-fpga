/* Triversity C5 firmware: host test of the FPGA link protocol (fpga_link.h).
 *   cc -std=c11 -Wall -Wextra -Werror -I../main test_fpga_link.c -o /tmp/t && /tmp/t */
#include <assert.h>
#include <stdio.h>
#include "fpga_link.h"

static int feed_all(fpga_link_t *p, const uint8_t *b, unsigned n, fpga_link_frame_t *out)
{
    int got = 0;
    for (unsigned k = 0; k < n; ++k) got += fpga_link_feed(p, b[k], out);
    return got;
}

int main(void)
{
    fpga_link_t p = {0};
    fpga_link_frame_t f;
    /* 'C' frames are the TANG9K_DUAL channel frames: check = 0x79 ^ index. */
    for (unsigned ch = 0; ch < 48; ++ch) assert(fpga_link_check('C', (uint8_t)ch) == (uint8_t)(0x79u ^ ch));
    const uint8_t c12[] = {0xC5, 'C', 12, 0x79 ^ 12};
    assert(feed_all(&p, c12, 4, &f) == 1 && f.tag == 'C' && f.value == 12);
    /* Every tag round-trips, also after garbage and a repeated sync. */
    const uint8_t tags[] = {'C', 'G', 'A', 'F', 'B'};
    for (unsigned t = 0; t < 5; ++t)
        for (unsigned v = 0; v < 256; v += 17) {
            const uint8_t fr[] = {0x00, 0xC5, 0xC5, tags[t], (uint8_t)v, fpga_link_check(tags[t], (uint8_t)v)};
            assert(feed_all(&p, fr, sizeof fr, &f) == 1 && f.tag == tags[t] && f.value == v);
        }
    assert(fpga_link_gain_action(FPGA_GAIN_NATIVE, 0) == FPGA_GAIN_TO_NATIVE);
    assert(fpga_link_gain_action(FPGA_GAIN_NATIVE, 1) == FPGA_GAIN_IGNORE);
    assert(fpga_link_gain_action(FPGA_GAIN_DIRECT_RESTORE, 1) == FPGA_GAIN_TO_DIRECT);
    assert(fpga_link_gain_action(FPGA_GAIN_DIRECT_RESTORE, 0) == FPGA_GAIN_IGNORE);
    assert(fpga_link_gain_action(255, 0) == FPGA_GAIN_IGNORE && fpga_link_gain_action(255, 1) == FPGA_GAIN_IGNORE);
    for (unsigned mode = 0; mode < FPGA_GAIN_NATIVE; ++mode) {
        assert(fpga_link_gain_action(mode, 0) == FPGA_GAIN_POLICY);
        assert(fpga_link_gain_action(mode, 1) == FPGA_GAIN_TO_DIRECT);
    }
    /* A wrong check byte or an unknown tag gives no frame. */
    const uint8_t bad[] = {0xC5, 'G', 1, (uint8_t)(fpga_link_check('G', 1) ^ 1), 0xC5, 'Z', 1, fpga_link_check('Z', 1)};
    assert(feed_all(&p, bad, sizeof bad, &f) == 0);
    /* Markers: preamble, alternating marker bits, payload round trip. */
    for (unsigned type = 1; type <= 6; ++type)
        for (unsigned value = 0; value < 4096; value += 37) {
            uint8_t w[FPGA_MARK_WORDS];
            fpga_mark_words(type, value, w);
            assert(w[0] == FPGA_MARK_PRE_A && w[1] == FPGA_MARK_PRE_B);
            for (unsigned k = 0; k < FPGA_MARK_WORDS; ++k) {
                assert(w[k] < 64u);
                if (k) assert(w[k] != w[k - 1]);   /* every word is a visible change on the pads */
            }
            const int payload = fpga_mark_decode(w + 2);
            assert(payload == (int)((type << 12) | value));
        }
    printf("test_fpga_link: PASS\n");
    return 0;
}
