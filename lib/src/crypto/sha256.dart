// SHA-256: port of C/Sha256.c (the portable Sha256_UpdateBlocks with the
// T8 unrolled rounds and a 64 word message schedule, Z7_SHA256_BIG_W).

import 'dart:typed_data';

/// SHA256_BLOCK_SIZE
const int kSha256BlockSize = 64;

/// SHA256_DIGEST_SIZE
const int kSha256DigestSize = 32;

// Message schedule, reused by every call (the code is synchronous).
final Uint32List _w = Uint32List(64);

// Sha256_UpdateBlocks
void sha256UpdateBlocks(
    Uint32List state, Uint8List data, int off, int numBlocks) {
  if (numBlocks == 0) return;
  final w = _w;
  var a = state[0];
  var b = state[1];
  var c = state[2];
  var d = state[3];
  var e = state[4];
  var f = state[5];
  var g = state[6];
  var h = state[7];
  do {
    for (var j = 0; j < 16; j++) {
      final p = off + j * 4;
      w[j] = (data[p] << 24) |
          (data[p + 1] << 16) |
          (data[p + 2] << 8) |
          data[p + 3];
    }
    for (var j = 16; j < 64; j++) {
      final x2 = w[j - 2];
      final x15 = w[j - 15];
      // s1(w[j-2]) + w[j-7] + s0(w[j-15]) + w[j-16]
      w[j] =
          (((x2 >> 17) | (x2 << 15)) ^ ((x2 >> 19) | (x2 << 13)) ^ (x2 >> 10)) +
              w[j - 7] +
              (((x15 >> 7) | (x15 << 25)) ^
                  ((x15 >> 18) | (x15 << 14)) ^
                  (x15 >> 3)) +
              w[j - 16];
    }
    // T8 round 0
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0x428a2f98 +
            w[0]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 1
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0x71374491 +
            w[1]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 2
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0xb5c0fbcf +
            w[2]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 3
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0xe9b5dba5 +
            w[3]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 4
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0x3956c25b +
            w[4]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 5
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0x59f111f1 +
            w[5]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 6
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0x923f82a4 +
            w[6]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 7
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0xab1c5ed5 +
            w[7]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 8
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0xd807aa98 +
            w[8]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 9
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0x12835b01 +
            w[9]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 10
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0x243185be +
            w[10]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 11
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0x550c7dc3 +
            w[11]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 12
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0x72be5d74 +
            w[12]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 13
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0x80deb1fe +
            w[13]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 14
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0x9bdc06a7 +
            w[14]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 15
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0xc19bf174 +
            w[15]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 16
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0xe49b69c1 +
            w[16]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 17
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0xefbe4786 +
            w[17]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 18
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0x0fc19dc6 +
            w[18]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 19
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0x240ca1cc +
            w[19]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 20
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0x2de92c6f +
            w[20]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 21
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0x4a7484aa +
            w[21]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 22
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0x5cb0a9dc +
            w[22]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 23
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0x76f988da +
            w[23]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 24
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0x983e5152 +
            w[24]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 25
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0xa831c66d +
            w[25]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 26
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0xb00327c8 +
            w[26]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 27
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0xbf597fc7 +
            w[27]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 28
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0xc6e00bf3 +
            w[28]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 29
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0xd5a79147 +
            w[29]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 30
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0x06ca6351 +
            w[30]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 31
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0x14292967 +
            w[31]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 32
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0x27b70a85 +
            w[32]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 33
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0x2e1b2138 +
            w[33]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 34
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0x4d2c6dfc +
            w[34]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 35
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0x53380d13 +
            w[35]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 36
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0x650a7354 +
            w[36]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 37
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0x766a0abb +
            w[37]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 38
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0x81c2c92e +
            w[38]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 39
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0x92722c85 +
            w[39]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 40
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0xa2bfe8a1 +
            w[40]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 41
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0xa81a664b +
            w[41]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 42
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0xc24b8b70 +
            w[42]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 43
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0xc76c51a3 +
            w[43]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 44
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0xd192e819 +
            w[44]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 45
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0xd6990624 +
            w[45]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 46
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0xf40e3585 +
            w[46]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 47
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0x106aa070 +
            w[47]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 48
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0x19a4c116 +
            w[48]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 49
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0x1e376c08 +
            w[49]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 50
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0x2748774c +
            w[50]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 51
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0x34b0bcb5 +
            w[51]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 52
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0x391c0cb3 +
            w[52]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 53
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0x4ed8aa4a +
            w[53]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 54
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0x5b9cca4f +
            w[54]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 55
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0x682e6ff3 +
            w[55]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    // T8 round 56
    h = (h +
            ((((e >> 6) | (e << 26)) ^
                    ((e >> 11) | (e << 21)) ^
                    ((e >> 25) | (e << 7))) &
                0xFFFFFFFF) +
            (g ^ (e & (f ^ g))) +
            0x748f82ee +
            w[56]) &
        0xFFFFFFFF;
    d = (d + h) & 0xFFFFFFFF;
    h = (h +
            ((((a >> 2) | (a << 30)) ^
                    ((a >> 13) | (a << 19)) ^
                    ((a >> 22) | (a << 10))) &
                0xFFFFFFFF) +
            ((a & b) | (c & (a | b)))) &
        0xFFFFFFFF;
    // T8 round 57
    g = (g +
            ((((d >> 6) | (d << 26)) ^
                    ((d >> 11) | (d << 21)) ^
                    ((d >> 25) | (d << 7))) &
                0xFFFFFFFF) +
            (f ^ (d & (e ^ f))) +
            0x78a5636f +
            w[57]) &
        0xFFFFFFFF;
    c = (c + g) & 0xFFFFFFFF;
    g = (g +
            ((((h >> 2) | (h << 30)) ^
                    ((h >> 13) | (h << 19)) ^
                    ((h >> 22) | (h << 10))) &
                0xFFFFFFFF) +
            ((h & a) | (b & (h | a)))) &
        0xFFFFFFFF;
    // T8 round 58
    f = (f +
            ((((c >> 6) | (c << 26)) ^
                    ((c >> 11) | (c << 21)) ^
                    ((c >> 25) | (c << 7))) &
                0xFFFFFFFF) +
            (e ^ (c & (d ^ e))) +
            0x84c87814 +
            w[58]) &
        0xFFFFFFFF;
    b = (b + f) & 0xFFFFFFFF;
    f = (f +
            ((((g >> 2) | (g << 30)) ^
                    ((g >> 13) | (g << 19)) ^
                    ((g >> 22) | (g << 10))) &
                0xFFFFFFFF) +
            ((g & h) | (a & (g | h)))) &
        0xFFFFFFFF;
    // T8 round 59
    e = (e +
            ((((b >> 6) | (b << 26)) ^
                    ((b >> 11) | (b << 21)) ^
                    ((b >> 25) | (b << 7))) &
                0xFFFFFFFF) +
            (d ^ (b & (c ^ d))) +
            0x8cc70208 +
            w[59]) &
        0xFFFFFFFF;
    a = (a + e) & 0xFFFFFFFF;
    e = (e +
            ((((f >> 2) | (f << 30)) ^
                    ((f >> 13) | (f << 19)) ^
                    ((f >> 22) | (f << 10))) &
                0xFFFFFFFF) +
            ((f & g) | (h & (f | g)))) &
        0xFFFFFFFF;
    // T8 round 60
    d = (d +
            ((((a >> 6) | (a << 26)) ^
                    ((a >> 11) | (a << 21)) ^
                    ((a >> 25) | (a << 7))) &
                0xFFFFFFFF) +
            (c ^ (a & (b ^ c))) +
            0x90befffa +
            w[60]) &
        0xFFFFFFFF;
    h = (h + d) & 0xFFFFFFFF;
    d = (d +
            ((((e >> 2) | (e << 30)) ^
                    ((e >> 13) | (e << 19)) ^
                    ((e >> 22) | (e << 10))) &
                0xFFFFFFFF) +
            ((e & f) | (g & (e | f)))) &
        0xFFFFFFFF;
    // T8 round 61
    c = (c +
            ((((h >> 6) | (h << 26)) ^
                    ((h >> 11) | (h << 21)) ^
                    ((h >> 25) | (h << 7))) &
                0xFFFFFFFF) +
            (b ^ (h & (a ^ b))) +
            0xa4506ceb +
            w[61]) &
        0xFFFFFFFF;
    g = (g + c) & 0xFFFFFFFF;
    c = (c +
            ((((d >> 2) | (d << 30)) ^
                    ((d >> 13) | (d << 19)) ^
                    ((d >> 22) | (d << 10))) &
                0xFFFFFFFF) +
            ((d & e) | (f & (d | e)))) &
        0xFFFFFFFF;
    // T8 round 62
    b = (b +
            ((((g >> 6) | (g << 26)) ^
                    ((g >> 11) | (g << 21)) ^
                    ((g >> 25) | (g << 7))) &
                0xFFFFFFFF) +
            (a ^ (g & (h ^ a))) +
            0xbef9a3f7 +
            w[62]) &
        0xFFFFFFFF;
    f = (f + b) & 0xFFFFFFFF;
    b = (b +
            ((((c >> 2) | (c << 30)) ^
                    ((c >> 13) | (c << 19)) ^
                    ((c >> 22) | (c << 10))) &
                0xFFFFFFFF) +
            ((c & d) | (e & (c | d)))) &
        0xFFFFFFFF;
    // T8 round 63
    a = (a +
            ((((f >> 6) | (f << 26)) ^
                    ((f >> 11) | (f << 21)) ^
                    ((f >> 25) | (f << 7))) &
                0xFFFFFFFF) +
            (h ^ (f & (g ^ h))) +
            0xc67178f2 +
            w[63]) &
        0xFFFFFFFF;
    e = (e + a) & 0xFFFFFFFF;
    a = (a +
            ((((b >> 2) | (b << 30)) ^
                    ((b >> 13) | (b << 19)) ^
                    ((b >> 22) | (b << 10))) &
                0xFFFFFFFF) +
            ((b & c) | (d & (b | c)))) &
        0xFFFFFFFF;
    a = (a + state[0]) & 0xFFFFFFFF;
    state[0] = a;
    b = (b + state[1]) & 0xFFFFFFFF;
    state[1] = b;
    c = (c + state[2]) & 0xFFFFFFFF;
    state[2] = c;
    d = (d + state[3]) & 0xFFFFFFFF;
    state[3] = d;
    e = (e + state[4]) & 0xFFFFFFFF;
    state[4] = e;
    f = (f + state[5]) & 0xFFFFFFFF;
    state[5] = f;
    g = (g + state[6]) & 0xFFFFFFFF;
    state[6] = g;
    h = (h + state[7]) & 0xFFFFFFFF;
    state[7] = h;
    off += kSha256BlockSize;
  } while (--numBlocks != 0);
}

/// CSha256
class Sha256 {
  final Uint32List state = Uint32List(8);
  int count = 0;
  final Uint8List buffer = Uint8List(kSha256BlockSize);

  Sha256() {
    init();
  }

  // Sha256_InitState / Sha256_Init
  void init() {
    count = 0;
    state[0] = 0x6a09e667;
    state[1] = 0xbb67ae85;
    state[2] = 0x3c6ef372;
    state[3] = 0xa54ff53a;
    state[4] = 0x510e527f;
    state[5] = 0x9b05688c;
    state[6] = 0x1f83d9ab;
    state[7] = 0x5be0cd19;
  }

  // Sha256_Update
  void update(Uint8List data, [int off = 0, int? size]) {
    var len = size ?? data.length - off;
    if (len == 0) return;
    {
      final pos = count & (kSha256BlockSize - 1);
      final num = kSha256BlockSize - pos;
      count += len;
      if (num > len) {
        buffer.setRange(pos, pos + len, data, off);
        return;
      }
      if (pos != 0) {
        len -= num;
        buffer.setRange(pos, pos + num, data, off);
        off += num;
        sha256UpdateBlocks(state, buffer, 0, 1);
      }
    }
    final numBlocks = len >> 6;
    sha256UpdateBlocks(state, data, off, numBlocks);
    len &= kSha256BlockSize - 1;
    if (len == 0) return;
    off += numBlocks << 6;
    buffer.setRange(0, len, data, off);
  }

  // Sha256_Final. Writes the digest to [digest] at [off] and resets the
  // state for a new hash.
  void finalTo(Uint8List digest, [int off = 0]) {
    var pos = count & (kSha256BlockSize - 1);
    buffer[pos++] = 0x80;
    if (pos > kSha256BlockSize - 4 * 2) {
      while (pos != kSha256BlockSize) {
        buffer[pos++] = 0;
      }
      sha256UpdateBlocks(state, buffer, 0, 1);
      pos = 0;
    }
    buffer.fillRange(pos, kSha256BlockSize - 4 * 2, 0);
    final numBits = count << 3;
    _setBe32(buffer, kSha256BlockSize - 8, (numBits >> 32) & 0xFFFFFFFF);
    _setBe32(buffer, kSha256BlockSize - 4, numBits & 0xFFFFFFFF);
    sha256UpdateBlocks(state, buffer, 0, 1);
    for (var i = 0; i < 8; i++) {
      _setBe32(digest, off + i * 4, state[i]);
    }
    init();
  }

  /// Sha256_Final into a new 32 byte list.
  Uint8List digest() {
    final out = Uint8List(kSha256DigestSize);
    finalTo(out);
    return out;
  }

  /// SHA-256 of [data].
  static Uint8List hash(Uint8List data) => (Sha256()..update(data)).digest();
}

void _setBe32(Uint8List b, int o, int v) {
  b[o] = v >> 24;
  b[o + 1] = v >> 16;
  b[o + 2] = v >> 8;
  b[o + 3] = v;
}
