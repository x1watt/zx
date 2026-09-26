// Huffman decoding tables: port of inftrees.c and inftrees.h of zlib 1.3.1
// and of inftree9.c and inftree9.h (contrib/infback9, the Deflate64
// variant), Mark Adler, zlib license (see LICENSE).
//
// A code (struct code of inftrees.h: op, bits, val) is packed in one
// Uint32List entry: op | bits << 8 | val << 16. A table pointer is an index
// in the Uint32List that holds it.

import 'dart:typed_data';

const int _maxbits = 15; // MAXBITS

/// Maximum size of the dynamic tables (inftrees.h): 852 entries for
/// literal/length codes and 592 for distance codes.
const int enoughLens = 852; // ENOUGH_LENS
const int enoughDists = 592; // ENOUGH_DISTS
const int enough = enoughLens + enoughDists; // ENOUGH

/// The Deflate64 sizes (inftree9.h).
const int enoughLens9 = 852; // ENOUGH_LENS
const int enoughDists9 = 594; // ENOUGH_DISTS
const int enough9 = enoughLens9 + enoughDists9; // ENOUGH

/// codetype
const int codesType = 0; // CODES
const int lensType = 1; // LENS
const int distsType = 2; // DISTS

/// Builds a code entry (op, bits, val).
int makeCode(int op, int bits, int val) => op | (bits << 8) | (val << 16);

// Length codes 257..285 base
final Uint16List _lbase = Uint16List.fromList(const [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, //
  67, 83, 99, 115, 131, 163, 195, 227, 258, 0, 0
]);
// Length codes 257..285 extra
final Uint16List _lext = Uint16List.fromList(const [
  16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 18, 18, 18, 18, 19, 19, //
  19, 19, 20, 20, 20, 20, 21, 21, 21, 21, 16, 203, 77
]);
// Distance codes 0..29 base
final Uint16List _dbase = Uint16List.fromList(const [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, //
  513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, //
  0, 0
]);
// Distance codes 0..29 extra
final Uint16List _dext = Uint16List.fromList(const [
  16, 16, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23, //
  24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 64, 64
]);

/// The result of [inflateTable] and [inflateTable9]: 0 is success, -1 an
/// invalid code, +1 means that ENOUGH isn't enough. [next] is the next free
/// entry of the table space, [bits] the actual root table index bits.
class InflateTableResult {
  int ret = 0;
  int next = 0;
  int bits = 0;
}

/// inflate_table: builds a set of tables to decode the provided canonical
/// Huffman code. The code lengths are lens[lensOff .. lensOff+codes-1].
/// The result starts at table[tableOff], whose indices are 0..2^bits-1.
/// [work] is a writable array of at least [codes] shorts. On return
/// [r].next is the next available entry and [r].bits the actual root table
/// index bits.
void inflateTable(int type, Uint16List lens, int lensOff, int codes,
    Uint32List table, int tableOff, int bits, Uint16List work,
    InflateTableResult r) {
  int len; // a code's length in bits
  int sym; // index of code symbols
  int min, max; // minimum and maximum code lengths
  int root; // number of index bits for root table
  int curr; // number of index bits for current table
  int drop; // code bits to drop for sub-table
  int left; // number of prefix codes available
  int used; // code entries in table used
  int huff; // Huffman code
  int incr; // for incrementing code, index
  int fill; // index for replicating entries
  int low; // low bits for current root entry
  int mask; // mask for low root bits
  int here; // table entry for duplication
  int next; // next available space in table
  Uint16List base; // base value table to use
  Uint16List extra; // extra bits table to use
  int match; // use base and extra for symbol >= match
  final count = Uint16List(_maxbits + 1); // number of codes of each length
  final offs = Uint16List(_maxbits + 1); // offsets in table for each length

  // accumulate lengths for codes (assumes lens[] all in 0..MAXBITS)
  for (sym = 0; sym < codes; sym++) {
    count[lens[lensOff + sym]]++;
  }

  // bound code lengths, force root to be within code lengths
  root = bits;
  for (max = _maxbits; max >= 1; max--) {
    if (count[max] != 0) break;
  }
  if (root > max) root = max;
  if (max == 0) {
    // no symbols to code at all
    here = makeCode(64, 1, 0); // invalid code marker
    table[tableOff] = here; // make a table to force an error
    table[tableOff + 1] = here;
    r.next = tableOff + 2;
    r.bits = 1;
    r.ret = 0; // no symbols, but wait for decoding to report error
    return;
  }
  for (min = 1; min < max; min++) {
    if (count[min] != 0) break;
  }
  if (root < min) root = min;

  // check for an over-subscribed or incomplete set of lengths
  left = 1;
  for (len = 1; len <= _maxbits; len++) {
    left <<= 1;
    left -= count[len];
    if (left < 0) {
      r.ret = -1; // over-subscribed
      return;
    }
  }
  if (left > 0 && (type == codesType || max != 1)) {
    r.ret = -1; // incomplete set
    return;
  }

  // generate offsets into symbol table for each length for sorting
  offs[1] = 0;
  for (len = 1; len < _maxbits; len++) {
    offs[len + 1] = offs[len] + count[len];
  }

  // sort symbols by length, by symbol order within each length
  for (sym = 0; sym < codes; sym++) {
    final l = lens[lensOff + sym];
    if (l != 0) work[offs[l]++] = sym;
  }

  // set up for code type
  switch (type) {
    case codesType:
      base = extra = work; // dummy value, not used
      match = 20;
    case lensType:
      base = _lbase;
      extra = _lext;
      match = 257;
    default: // DISTS
      base = _dbase;
      extra = _dext;
      match = 0;
  }

  // initialize state for loop
  huff = 0; // starting code
  sym = 0; // starting code symbol
  len = min; // starting code length
  next = tableOff; // current table to fill in
  curr = root; // current table index bits
  drop = 0; // current bits to drop from code for index
  low = -1; // trigger new sub-table when len > root
  used = 1 << root; // use root table entries
  mask = used - 1; // mask for comparing low

  // check available table space
  if ((type == lensType && used > enoughLens) ||
      (type == distsType && used > enoughDists)) {
    r.ret = 1;
    return;
  }

  // process all codes and make table entries
  for (;;) {
    // create table entry
    final ws = work[sym];
    if (ws + 1 < match) {
      here = makeCode(0, len - drop, ws);
    } else if (ws >= match) {
      here = makeCode(extra[ws - match], len - drop, base[ws - match]);
    } else {
      here = makeCode(32 + 64, len - drop, 0); // end of block
    }

    // replicate for those indices with low len bits equal to huff
    incr = 1 << (len - drop);
    fill = 1 << curr;
    min = fill; // save offset to next table
    do {
      fill -= incr;
      table[next + (huff >> drop) + fill] = here;
    } while (fill != 0);

    // backwards increment the len-bit code huff
    incr = 1 << (len - 1);
    while ((huff & incr) != 0) {
      incr >>= 1;
    }
    if (incr != 0) {
      huff &= incr - 1;
      huff += incr;
    } else {
      huff = 0;
    }

    // go to next symbol, update count, len
    sym++;
    if (--count[len] == 0) {
      if (len == max) break;
      len = lens[lensOff + work[sym]];
    }

    // create new sub-table if needed
    if (len > root && (huff & mask) != low) {
      // if first time, transition to sub-tables
      if (drop == 0) drop = root;

      // increment past last table
      next += min; // here min is 1 << curr

      // determine length of next table
      curr = len - drop;
      left = 1 << curr;
      while (curr + drop < max) {
        left -= count[curr + drop];
        if (left <= 0) break;
        curr++;
        left <<= 1;
      }

      // check for enough space
      used += 1 << curr;
      if ((type == lensType && used > enoughLens) ||
          (type == distsType && used > enoughDists)) {
        r.ret = 1;
        return;
      }

      // point entry in root table to sub-table
      low = huff & mask;
      table[tableOff + low] = makeCode(curr, root, next - tableOff);
    }
  }

  // fill in remaining table entry if code is incomplete (guaranteed to have
  // at most one remaining entry, since if the code is incomplete, the
  // maximum code length that was allowed to get this far is one bit)
  if (huff != 0) {
    table[next + huff] = makeCode(64, len - drop, 0); // invalid code marker
  }

  // set return parameters
  r.next = tableOff + used;
  r.bits = root;
  r.ret = 0;
}

// inftree9.c: Length codes 257..285 base
final Uint16List _lbase9 = Uint16List.fromList(const [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, //
  67, 83, 99, 115, 131, 163, 195, 227, 3, 0, 0
]);
// inftree9.c: Length codes 257..285 extra
final Uint16List _lext9 = Uint16List.fromList(const [
  128, 128, 128, 128, 128, 128, 128, 128, 129, 129, 129, 129, 130, 130, //
  130, 130, 131, 131, 131, 131, 132, 132, 132, 132, 133, 133, 133, 133, //
  144, 203, 77
]);
// inftree9.c: Distance codes 0..31 base
final Uint16List _dbase9 = Uint16List.fromList(const [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, //
  513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, //
  32769, 49153
]);
// inftree9.c: Distance codes 0..31 extra
final Uint16List _dext9 = Uint16List.fromList(const [
  128, 128, 128, 128, 129, 129, 130, 130, 131, 131, 132, 132, 133, 133, //
  134, 134, 135, 135, 136, 136, 137, 137, 138, 138, 139, 139, 140, 140, //
  141, 141, 142, 142
]);

/// inflate_table9 (inftree9.c): the Deflate64 variant of [inflateTable].
/// Its length and distance entries use op 128 + extra bits, code 285 is a
/// length base 3 with 16 extra bits, distance codes 30 and 31 are used,
/// an empty code is an error and incomplete codes get invalid markers in
/// every remaining entry.
void inflateTable9(int type, Uint16List lens, int lensOff, int codes,
    Uint32List table, int tableOff, int bits, Uint16List work,
    InflateTableResult r) {
  int len; // a code's length in bits
  int sym; // index of code symbols
  int min, max; // minimum and maximum code lengths
  int root; // number of index bits for root table
  int curr; // number of index bits for current table
  int drop; // code bits to drop for sub-table
  int left; // number of prefix codes available
  int used; // code entries in table used
  int huff; // Huffman code
  int incr; // for incrementing code, index
  int fill; // index for replicating entries
  int low; // low bits for current root entry
  int mask; // mask for low root bits
  int thisCode; // table entry for duplication
  int next; // next available space in table
  Uint16List base; // base value table to use
  int baseOff; // base -= 257 for LENS
  Uint16List extra; // extra bits table to use
  int end; // use base and extra for symbol > end
  final count = Uint16List(_maxbits + 1); // number of codes of each length
  final offs = Uint16List(_maxbits + 1); // offsets in table for each length

  // accumulate lengths for codes (assumes lens[] all in 0..MAXBITS)
  for (sym = 0; sym < codes; sym++) {
    count[lens[lensOff + sym]]++;
  }

  // bound code lengths, force root to be within code lengths
  root = bits;
  for (max = _maxbits; max >= 1; max--) {
    if (count[max] != 0) break;
  }
  if (root > max) root = max;
  if (max == 0) {
    r.ret = -1; // no codes!
    return;
  }
  for (min = 1; min <= _maxbits; min++) {
    if (count[min] != 0) break;
  }
  if (root < min) root = min;

  // check for an over-subscribed or incomplete set of lengths
  left = 1;
  for (len = 1; len <= _maxbits; len++) {
    left <<= 1;
    left -= count[len];
    if (left < 0) {
      r.ret = -1; // over-subscribed
      return;
    }
  }
  if (left > 0 && (type == codesType || max != 1)) {
    r.ret = -1; // incomplete set
    return;
  }

  // generate offsets into symbol table for each length for sorting
  offs[1] = 0;
  for (len = 1; len < _maxbits; len++) {
    offs[len + 1] = offs[len] + count[len];
  }

  // sort symbols by length, by symbol order within each length
  for (sym = 0; sym < codes; sym++) {
    final l = lens[lensOff + sym];
    if (l != 0) work[offs[l]++] = sym;
  }

  // set up for code type
  switch (type) {
    case codesType:
      base = extra = work; // dummy value, not used
      baseOff = 0;
      end = 19;
    case lensType:
      base = _lbase9;
      extra = _lext9;
      baseOff = -257; // base -= 257; extra -= 257;
      end = 256;
    default: // DISTS
      base = _dbase9;
      extra = _dext9;
      baseOff = 0;
      end = -1;
  }

  // initialize state for loop
  huff = 0; // starting code
  sym = 0; // starting code symbol
  len = min; // starting code length
  next = tableOff; // current table to fill in
  curr = root; // current table index bits
  drop = 0; // current bits to drop from code for index
  low = -1; // trigger new sub-table when len > root
  used = 1 << root; // use root table entries
  mask = used - 1; // mask for comparing low

  // check available table space
  if ((type == lensType && used >= enoughLens9) ||
      (type == distsType && used >= enoughDists9)) {
    r.ret = 1;
    return;
  }

  // process all codes and make table entries
  for (;;) {
    // create table entry
    final ws = work[sym];
    if (ws < end) {
      thisCode = makeCode(0, len - drop, ws);
    } else if (ws > end) {
      thisCode =
          makeCode(extra[ws + baseOff], len - drop, base[ws + baseOff]);
    } else {
      thisCode = makeCode(32 + 64, len - drop, 0); // end of block
    }

    // replicate for those indices with low len bits equal to huff
    incr = 1 << (len - drop);
    fill = 1 << curr;
    do {
      fill -= incr;
      table[next + (huff >> drop) + fill] = thisCode;
    } while (fill != 0);

    // backwards increment the len-bit code huff
    incr = 1 << (len - 1);
    while ((huff & incr) != 0) {
      incr >>= 1;
    }
    if (incr != 0) {
      huff &= incr - 1;
      huff += incr;
    } else {
      huff = 0;
    }

    // go to next symbol, update count, len
    sym++;
    if (--count[len] == 0) {
      if (len == max) break;
      len = lens[lensOff + work[sym]];
    }

    // create new sub-table if needed
    if (len > root && (huff & mask) != low) {
      // if first time, transition to sub-tables
      if (drop == 0) drop = root;

      // increment past last table
      next += 1 << curr;

      // determine length of next table
      curr = len - drop;
      left = 1 << curr;
      while (curr + drop < max) {
        left -= count[curr + drop];
        if (left <= 0) break;
        curr++;
        left <<= 1;
      }

      // check for enough space
      used += 1 << curr;
      if ((type == lensType && used >= enoughLens9) ||
          (type == distsType && used >= enoughDists9)) {
        r.ret = 1;
        return;
      }

      // point entry in root table to sub-table
      low = huff & mask;
      table[tableOff + low] = makeCode(curr, root, next - tableOff);
    }
  }

  // Fill in rest of table for incomplete codes. This loop is similar to
  // the loop above in incrementing huff for table indices. It is assumed
  // that len is equal to curr + drop, so there is no loop needed to
  // increment through high index bits. When the current sub-table is
  // filled, the loop drops back to the root table to fill in any remaining
  // entries there.
  thisCode = makeCode(64, len - drop, 0); // invalid code marker
  while (huff != 0) {
    // when done with sub-table, drop back to root table
    if (drop != 0 && (huff & mask) != low) {
      drop = 0;
      len = root;
      next = tableOff;
      curr = root;
      thisCode = makeCode(64, len, 0);
    }

    // put invalid code marker in table
    table[next + (huff >> drop)] = thisCode;

    // backwards increment the len-bit code huff
    incr = 1 << (len - 1);
    while ((huff & incr) != 0) {
      incr >>= 1;
    }
    if (incr != 0) {
      huff &= incr - 1;
      huff += incr;
    } else {
      huff = 0;
    }
  }

  // set return parameters
  r.next = tableOff + used;
  r.bits = root;
  r.ret = 0;
}
