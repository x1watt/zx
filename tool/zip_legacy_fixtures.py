#!/usr/bin/env python3
"""Builds the zip fixtures of test/zip_legacy_test.dart.

Reference encoders for the legacy zip methods 1 (Shrink), 2 to 5 (Reduce)
and 6 (Implode), written from the PKWARE APPNOTE (sections 5.1 to 5.3).
No tool on the build machine writes these methods, so the archives made
here are checked with `unzip -t` and `7z t` (run with --check) and then
decoded by the Dart decoders.

Each archive holds one entry. Its name is "<kind>-<size>-<seed>.bin": the
Dart test regenerates the content from it with the same generator as
gen_content() below, so only the archives are committed.

Usage: python3 tool/zip_legacy_fixtures.py [--check] [out_dir]
"""

import heapq
import os
import struct
import subprocess
import sys
import zlib

M32 = 0xFFFFFFFF


# ---------------------------------------------------------------------------
# Deterministic content (mirrored by genContent in test/zip_legacy_test.dart)

WORDS = [b'shrink', b'reduce', b'implode', b'the', b'of', b'zip', b'tree',
         b'code', b'window', b'length', b'distance', b'follower', b'set',
         b'literal', b'a', b'and', b'data', b'Shannon', b'Fano', b'LZW']


class XorShift:
    def __init__(self, seed):
        self.s = (seed * 2654435761 + 1) & M32 or 1

    def next(self):
        s = self.s
        s ^= (s << 13) & M32
        s ^= s >> 17
        s ^= (s << 5) & M32
        self.s = s
        return s


def gen_content(kind, n, seed):
    rnd = XorShift(seed)
    out = bytearray()
    if kind == 'rep':
        return b'a' * n
    if kind == 'zbin':
        out += bytes(300)
        kind = 'bin'
    while len(out) < n:
        r = rnd.next()
        if kind == 'text':
            out += WORDS[r % len(WORDS)]
            out += b'\n' if (r >> 8) % 11 == 0 else b' '
        elif kind == 'bin':
            op = r % 4
            if op == 0:
                for _ in range(1 + (r >> 4) % 32):
                    out.append(rnd.next() & 0xFF)
            elif op == 1 and out:
                lim = len(out) if len(out) < 5000 else 5000
                dist = 1 + (r >> 4) % lim
                for _ in range(3 + (r >> 16) % 300):
                    out.append(out[len(out) - dist])
            elif op == 2:
                out += bytes([(r >> 4) & 0xFF]) * (1 + (r >> 12) % 100)
            else:
                out += b'\x90' * (1 + (r >> 4) % 20)
        elif kind == 'dle':
            op = r % 3
            if op == 0:
                out += b'\x90' * (1 + (r >> 4) % 40)
            elif op == 1:
                out.append(0x90 if (r >> 4) & 1 else (r >> 5) & 0xFF)
            else:
                out += WORDS[(r >> 4) % len(WORDS)]
        else:
            raise ValueError(kind)
    return bytes(out[:n])


# ---------------------------------------------------------------------------
# Bit output, least significant bit first (all three methods pack this way)

class BitWriter:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def write(self, v, bits):
        self.acc |= (v & ((1 << bits) - 1)) << self.n
        self.n += bits
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def finish(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
        self.acc = 0
        self.n = 0
        return bytes(self.out)


# ---------------------------------------------------------------------------
# Method 1: Shrink (LZW, codes of 9 to 13 bits, partial clearing)
#
# Code 256 is a control code: it is followed by a subcode written at the same
# size, 1 to grow the code size by one bit, 2 for a partial clear. Codes 257
# to 8191 are strings: a prefix code plus one byte. The decoder adds a string
# when it reads a code (previous code plus the first byte of the new one), so
# the encoder adds the matching string only after any control codes it puts
# between two codes. A partial clear frees every string that no other string
# uses as its prefix (one pass). Free codes are handed out lowest first.
#
# The encoder clears as soon as the table is full: Info-ZIP unzip 6 rejects
# a stream that goes on writing codes with a full table (7-Zip accepts it).
# A clear may free the code just written, and the string added right after
# it then has a freed prefix. Freed entries keep their data until they are
# given out again and strings resolve through the current table; 7-Zip reads
# streams that later write such a string that way, unzip rejects them, so
# only the fixture shrink_hang does it (hang_used in the stats).

def shrink(data, clear_every=0, stats=None):
    bw = BitWriter()
    if not data:
        return b''
    size = 9
    table = {}
    key = [None] * 8192
    children = [0] * 8192
    used = [False] * 8192
    free = [257]
    st = {'clears': 0, 'freed_prev': 0, 'self': 0, 'hang_used': 0}
    hang = set()

    def next_free():
        f = free[0]
        while f < 8192 and used[f]:
            f += 1
        free[0] = f
        return f

    def put(code):
        nonlocal size
        while code >= (1 << size):
            bw.write(256, size)
            bw.write(1, size)
            size += 1
        bw.write(code, size)
        if code in hang:
            st['hang_used'] += 1

    def partial_clear():
        leaves = [c for c in range(257, 8192) if used[c] and children[c] == 0]
        for c in leaves:
            used[c] = False
            p, _ = key[c]
            del table[key[c]]
            key[c] = None
            hang.discard(c)
            if p >= 257:
                children[p] -= 1
        free[0] = 257
        st['clears'] += 1

    w = data[0]
    written = 0
    for c in data[1:]:
        k = (w, c)
        code = table.get(k)
        if code is not None:
            w = code
            continue
        put(w)
        written += 1
        if next_free() >= 8192 or (clear_every and written % clear_every == 0):
            bw.write(256, size)
            bw.write(2, size)
            partial_clear()
        f = next_free()
        if f < 8192:
            if w >= 257 and not used[w]:
                st['freed_prev'] += 1
                hang.add(f)
                if f == w:
                    st['self'] += 1
            used[f] = True
            table[k] = f
            key[f] = k
            if w >= 257:
                children[w] += 1
        w = c
    put(w)
    if stats is not None:
        stats.update(st)
        stats['size'] = size
    return bw.finish()


# ---------------------------------------------------------------------------
# Methods 2 to 5: Reduce with compression factor 1 to 4

def b_bits(n):
    # Bits of a follower set index: enough for n - 1, at least 1.
    return 1 if n <= 2 else (n - 1).bit_length()


def reduce_lz(data, factor, zero_prefix):
    """First stage: DLE (0x90) coded matches over the previous bytes."""
    mask = (1 << (8 - factor)) - 1
    max_dist = (1 << factor) * 256
    max_len = mask + 255 + 3
    pre = max_dist if zero_prefix else 0
    buf = bytes(pre) + data
    heads = {}
    out = bytearray()
    for i in range(0, pre - 2):
        heads.setdefault(buf[i:i + 3], []).append(i)
    i = pre
    end = len(buf)
    while i < end:
        best_len = 0
        best_dist = 0
        if i + 3 <= end:
            cands = heads.get(buf[i:i + 3], [])
            for p in reversed(cands[-48:]):
                d = i - p
                if d > max_dist:
                    break
                ln = 0
                lim = min(max_len, end - i)
                while ln < lim and buf[p + ln] == buf[i + ln]:
                    ln += 1
                if ln == 3 and d <= 256:
                    continue  # would need V = 0, which means a literal DLE
                if ln > best_len:
                    best_len = ln
                    best_dist = d
        if best_len >= 3:
            ln = best_len - 3
            hi = (best_dist - 1) >> 8
            lo = (best_dist - 1) & 0xFF
            if ln >= mask:
                out += bytes([0x90, (hi << (8 - factor)) | mask, ln - mask, lo])
            else:
                out += bytes([0x90, (hi << (8 - factor)) | ln, lo])
            step = best_len
        else:
            b = buf[i]
            out += b'\x90\x00' if b == 0x90 else bytes([b])
            step = 1
        for j in range(i, min(i + step, end - 2)):
            heads.setdefault(buf[j:j + 3], []).append(j)
        i += step
    return bytes(out)


def reduce(data, factor, zero_prefix=False, stats=None):
    s = reduce_lz(data, factor, zero_prefix)
    counts = [dict() for _ in range(256)]
    last = 0
    for b in s:
        counts[last][b] = counts[last].get(b, 0) + 1
        last = b
    sets = []
    for j in range(256):
        cand = sorted(counts[j].items(), key=lambda kv: (-kv[1], kv[0]))
        sets.append([b for b, n in cand if n >= 2][:32])
    bw = BitWriter()
    for j in range(255, -1, -1):
        bw.write(len(sets[j]), 6)
        for b in sets[j]:
            bw.write(b, 8)
    index = [{b: k for k, b in enumerate(st)} for st in sets]
    last = 0
    for b in s:
        st = sets[last]
        if not st:
            bw.write(b, 8)
        else:
            k = index[last].get(b)
            if k is None:
                bw.write(1, 1)
                bw.write(b, 8)
            else:
                bw.write(0, 1)
                bw.write(k, b_bits(len(st)))
        last = b
    if stats is not None:
        sizes = [len(st) for st in sets]
        stats['set1'] = sizes.count(1)
        stats['sets'] = sum(1 for x in sizes if x)
        stats['dle'] = s.count(0x90)
    return bw.finish()


# ---------------------------------------------------------------------------
# Method 6: Implode (sliding dictionary plus Shannon-Fano trees)

def code_lengths(freqs, limit=16):
    """Huffman code lengths, every symbol at least 1 bit, at most limit."""
    f = [x + 1 for x in freqs]
    while True:
        heap = [(x, i, (i,)) for i, x in enumerate(f)]
        heapq.heapify(heap)
        lens = [0] * len(f)
        tie = len(f)
        while len(heap) > 1:
            a = heapq.heappop(heap)
            b = heapq.heappop(heap)
            for s in a[2] + b[2]:
                lens[s] += 1
            heapq.heappush(heap, (a[0] + b[0], tie, a[2] + b[2]))
            tie += 1
        if max(lens) <= limit:
            return lens
        f = [(x >> 1) + 1 for x in f]


def sf_codes(lens):
    """APPNOTE 5.3.8: codes as 16-bit left aligned values."""
    n = len(lens)
    order = sorted(range(n), key=lambda i: (lens[i], i))
    code = 0
    inc = 0
    last = 0
    codes = [0] * n
    for k in range(n - 1, -1, -1):
        i = order[k]
        code += inc
        if lens[i] != last:
            last = lens[i]
            inc = 1 << (16 - last)
        codes[i] = code
    assert code + inc == 1 << 16, 'incomplete tree'
    return codes


def put_tree(out, lens):
    runs = bytearray()
    i = 0
    while i < len(lens):
        j = i
        while j < len(lens) and lens[j] == lens[i] and j - i < 16:
            j += 1
        runs.append(((j - i - 1) << 4) | (lens[i] - 1))
        i = j
    out.append(len(runs) - 1)
    out += runs


def put_code(bw, code, ln):
    # The code is sent from its most significant bit on, one bit at a time.
    v = code >> (16 - ln)
    for k in range(ln - 1, -1, -1):
        bw.write((v >> k) & 1, 1)


def implode(data, big, lit, zero_prefix=False, stats=None):
    wsize = 8192 if big else 4096
    dbits = 7 if big else 6
    min_len = 3 if lit else 2
    max_len = min_len + 63 + 255
    pre = wsize if zero_prefix else 0
    buf = bytes(pre) + data
    heads = {}
    for i in range(0, pre - min_len + 1):
        heads.setdefault(buf[i:i + min_len], []).append(i)
    tokens = []
    i = pre
    end = len(buf)
    while i < end:
        best_len = 0
        best_dist = 0
        if i + min_len <= end:
            cands = heads.get(buf[i:i + min_len], [])
            for p in reversed(cands[-64:]):
                d = i - p
                if d > wsize:
                    break
                ln = 0
                lim = min(max_len, end - i)
                while ln < lim and buf[p + ln] == buf[i + ln]:
                    ln += 1
                if ln > best_len:
                    best_len = ln
                    best_dist = d
        if best_len >= min_len:
            tokens.append((best_len, best_dist - 1))
            step = best_len
        else:
            tokens.append((0, buf[i]))
            step = 1
        for j in range(i, min(i + step, end - min_len + 1)):
            heads.setdefault(buf[j:j + min_len], []).append(j)
        i += step

    lit_f = [0] * 256
    len_f = [0] * 64
    dist_f = [0] * 64
    for ln, v in tokens:
        if ln == 0:
            lit_f[v] += 1
        else:
            len_f[min(ln - min_len, 63)] += 1
            dist_f[v >> dbits] += 1
    head = bytearray()
    if lit:
        lit_l = code_lengths(lit_f)
        lit_c = sf_codes(lit_l)
        put_tree(head, lit_l)
    len_l = code_lengths(len_f)
    len_c = sf_codes(len_l)
    put_tree(head, len_l)
    dist_l = code_lengths(dist_f)
    dist_c = sf_codes(dist_l)
    put_tree(head, dist_l)

    bw = BitWriter()
    long_matches = 0
    for ln, v in tokens:
        if ln == 0:
            bw.write(1, 1)
            if lit:
                put_code(bw, lit_c[v], lit_l[v])
            else:
                bw.write(v, 8)
        else:
            bw.write(0, 1)
            bw.write(v, dbits)
            hi = v >> dbits
            put_code(bw, dist_c[hi], dist_l[hi])
            sym = min(ln - min_len, 63)
            put_code(bw, len_c[sym], len_l[sym])
            if sym == 63:
                bw.write(ln - min_len - 63, 8)
                long_matches += 1
    if stats is not None:
        stats['matches'] = sum(1 for t in tokens if t[0])
        stats['long'] = long_matches
    return bytes(head) + bw.finish()


# ---------------------------------------------------------------------------
# Zip container: one local header, the data, the central directory, the end

def make_zip(name, data, packed, method, flags, version):
    crc = zlib.crc32(data) & M32
    fname = name.encode()
    time, date = 0x6000, 0x5B3A  # 2025-09-26 12:00:00
    local = struct.pack('<IHHHHHIIIHH', 0x04034B50, version, flags, method,
                        time, date, crc, len(packed), len(data), len(fname), 0)
    central = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, version, version,
                          flags, method, time, date, crc, len(packed),
                          len(data), len(fname), 0, 0, 0, 0, 0, 0)
    cd_off = len(local) + len(fname) + len(packed)
    cd = central + fname
    eocd = struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, 1, 1, len(cd), cd_off, 0)
    return local + fname + packed + cd + eocd


# name, method, flags, version, content (kind, size, seed), encoder options
FIXTURES = [
    ('shrink_text', 1, 0, 10, ('text', 3000, 1), {}),
    ('shrink_kwkwk', 1, 0, 10, ('rep', 2000, 0), {}),
    ('shrink_clear', 1, 0, 20, ('text', 20000, 2), {'clear_every': 700}),
    ('shrink_clear3', 1, 0, 10, ('text', 6000, 18), {'clear_every': 3}),
    ('shrink_big', 1, 0, 10, ('bin', 100000, 3), {}),
    # Uses strings added after their prefix was freed: 7z only (see above).
    ('shrink_hang', 1, 0, 10, ('bin', 8000, 5), {'clear_every': 2}),
    ('reduce1_text', 2, 0, 10, ('text', 4000, 4), {}),
    ('reduce2_text', 3, 0, 10, ('text', 4000, 5), {}),
    ('reduce3_text', 4, 0, 10, ('text', 4000, 6), {}),
    ('reduce4_text', 5, 0, 10, ('text', 4000, 7), {}),
    ('reduce1_dle', 2, 0, 10, ('dle', 4000, 8), {}),
    ('reduce2_dle', 3, 0, 10, ('dle', 4000, 9), {}),
    ('reduce3_dle', 4, 0, 20, ('dle', 4000, 10), {}),
    ('reduce4_dle', 5, 0, 10, ('dle', 4000, 11), {}),
    ('reduce4_bin', 5, 0, 10, ('zbin', 6000, 12), {'zero_prefix': True}),
    ('implode_4k_2t_text', 6, 0, 10, ('text', 5000, 13), {}),
    ('implode_8k_3t_text', 6, 6, 10, ('text', 5000, 14), {}),
    ('implode_4k_3t_bin', 6, 4, 20, ('bin', 6000, 15), {}),
    ('implode_8k_2t_bin', 6, 2, 10, ('bin', 6000, 16), {}),
    ('implode_8k_3t_zbin', 6, 6, 10, ('zbin', 4000, 17),
     {'zero_prefix': True}),
    ('implode_4k_2t_rep', 6, 0, 10, ('rep', 3000, 0), {}),
]


def encode(method, flags, data, opts, stats):
    if method == 1:
        return shrink(data, opts.get('clear_every', 0), stats)
    if 2 <= method <= 5:
        return reduce(data, method - 1, opts.get('zero_prefix', False), stats)
    return implode(data, bool(flags & 2), bool(flags & 4),
                   opts.get('zero_prefix', False), stats)


def main():
    args = sys.argv[1:]
    check = '--check' in args
    args = [a for a in args if a != '--check']
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = args[0] if args else os.path.join(root, 'test', 'data',
                                                'zip_legacy')
    os.makedirs(out_dir, exist_ok=True)
    total = 0
    for name, method, flags, version, (kind, n, seed), opts in FIXTURES:
        data = gen_content(kind, n, seed)
        stats = {}
        packed = encode(method, flags, data, opts, stats)
        z = make_zip('%s-%d-%d.bin' % (kind, n, seed), data, packed, method,
                     flags, version)
        path = os.path.join(out_dir, name + '.zip')
        with open(path, 'wb') as fh:
            fh.write(z)
        total += len(z)
        line = '%-22s %6d to %6d %s' % (name, len(data), len(packed), stats)
        if check:
            u = subprocess.run(['unzip', '-tqq', path], capture_output=True)
            s = subprocess.run(['7z', 't', path], capture_output=True)
            line += '  unzip:%s 7z:%s' % (
                'ok' if u.returncode == 0 else 'FAIL',
                'ok' if s.returncode == 0 else 'FAIL')
        print(line)
    print('total %d bytes' % total)


if __name__ == '__main__':
    main()
