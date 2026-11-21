"""Triversity: TMDS encoding (DVI 1.0, 3.2.1) and decoding, the reference for
rtl/video/tmds_enc.v. cnt is kept as (ones - zeros) / 2 like the RTL (the
spec's counter halved: its updates are always even)."""
CTRL = {0: 0b1101010100, 1: 0b0010101011, 2: 0b0101010100, 3: 0b1010101011}


def encode(stream):
    """[(de, d, c)] -> [10-bit symbols]"""
    out, cnt = [], 0
    for de, d, c in stream:
        if not de:
            cnt = 0
            out.append(CTRL[c])
            continue
        n1d = bin(d).count('1')
        xn = n1d > 4 or (n1d == 4 and not d & 1)
        qm = d & 1
        for i in range(1, 8):
            b = ((qm >> (i - 1)) ^ (d >> i)) & 1
            qm |= ((b ^ 1) if xn else b) << i
        q8 = 0 if xn else 1
        bal = bin(qm & 255).count('1') - 4
        if cnt == 0 or bal == 0:
            q = ((q8 ^ 1) << 9) | (q8 << 8) | (qm if q8 else (~qm & 255))
            cnt = cnt + bal if q8 else cnt - bal
        elif (cnt > 0 and bal > 0) or (cnt < 0 and bal < 0):
            q = (1 << 9) | (q8 << 8) | (~qm & 255)
            cnt = cnt + q8 - bal
        else:
            q = (q8 << 8) | qm
            cnt = cnt - (q8 ^ 1) + bal
        out.append(q)
    return out


def decode(q):
    """10-bit symbol -> ('d', byte) or ('c', control)"""
    for c, s in CTRL.items():
        if q == s:
            return 'c', c
    d = q & 255
    if q >> 9 & 1:
        d ^= 255
    v = d & 1
    for i in range(1, 8):
        b = ((d >> i) ^ (d >> (i - 1))) & 1
        v |= (b if q >> 8 & 1 else b ^ 1) << i
    return 'd', v
