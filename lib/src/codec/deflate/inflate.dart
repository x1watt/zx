// Raw inflate: port of inflate.c, inflate.h and inffast.c of zlib 1.3.1
// (Mark Adler, zlib license, see LICENSE).
//
// The port keeps the stream interface of zlib (next_in, avail_in, next_out,
// avail_out and inflate(strm, flush)). Only raw inflate is ported
// (windowBits -8..-15 in zlib terms): the zlib and gzip header and trailer
// states (HEAD with a wrapper, FLAGS .. HCRC, DICTID, DICT and the check
// of CHECK / LENGTH) are not, the gzip handler parses its own header and
// trailer. inflateSetDictionary, inflateSync, inflateCopy and inflatePrime
// are not ported either. The fixed tables are built at first use (the
// BUILDFIXED path of fixedtables), which gives the tables of inffixed.h.

import 'dart:typed_data';

import 'inftrees.dart';
import 'zutil.dart';

// inflate_mode (inflate.h)
const int _head = 16180; // i: waiting for magic header
const int _type = 16191; // i: waiting for type bits, including last-flag bit
const int _typedo = 16192; // i: same, but skip check to exit on new block
const int _stored = 16193; // i: waiting for stored size
const int _copy_ = 16194; // i/o: same as COPY below, but only first time in
const int _copy = 16195; // i/o: waiting for input or output to copy stored
const int _table = 16196; // i: waiting for dynamic block table lengths
const int _lenlens = 16197; // i: waiting for code length code lengths
const int _codelens = 16198; // i: waiting for length/lit and distance lengths
const int _len_ = 16199; // i: same as LEN below, but only first time in
const int _len = 16200; // i: waiting for length/lit/eob code
const int _lenext = 16201; // i: waiting for length extra bits
const int _dist = 16202; // i: waiting for distance code
const int _distext = 16203; // i: waiting for distance extra bits
const int _match = 16204; // o: waiting for output space to copy string
const int _lit = 16205; // o: waiting for output space to write literal
const int _check = 16206; // i: waiting for 32-bit check value
const int _length = 16207; // i: waiting for 32-bit length (gzip)
const int _done = 16208; // finished check, done
const int _bad = 16209; // got a data error
const int _mem = 16210; // got an inflate() memory error
const int _sync = 16211; // looking for synchronization bytes

// permutation of code lengths
const List<int> _order = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 //
];

/// The fixed tables (lenfix at 0, distfix at 512) built by fixedtables.
final Uint32List _fixed = _buildFixed();

// fixedtables (BUILDFIXED)
Uint32List _buildFixed() {
  final fixed = Uint32List(544);
  final lens = Uint16List(320);
  final work = Uint16List(288);
  final r = InflateTableResult();

  // literal/length table
  var sym = 0;
  while (sym < 144) {
    lens[sym++] = 8;
  }
  while (sym < 256) {
    lens[sym++] = 9;
  }
  while (sym < 280) {
    lens[sym++] = 7;
  }
  while (sym < 288) {
    lens[sym++] = 8;
  }
  inflateTable(lensType, lens, 0, 288, fixed, 0, 9, work, r);

  // distance table
  sym = 0;
  while (sym < 32) {
    lens[sym++] = 5;
  }
  inflateTable(distsType, lens, 0, 32, fixed, r.next, 5, work, r);
  return fixed;
}

/// The raw inflater: the z_stream fields used by inflate() plus struct
/// inflate_state of inflate.h.
class InflateState {
  // ---- z_stream ----

  /// next input byte is nextIn[nextInPos]; availIn bytes are available.
  Uint8List nextIn = Uint8List(0);
  int nextInPos = 0;
  int availIn = 0;

  /// total number of input bytes read so far
  int totalIn = 0;

  /// next output byte goes to nextOut[nextOutPos]; availOut bytes free.
  Uint8List nextOut = Uint8List(0);
  int nextOutPos = 0;
  int availOut = 0;

  /// total number of bytes output so far
  int totalOut = 0;

  /// last error message, null if no error
  String? msg;

  /// data_type: the number of unused bits in the last byte taken from
  /// nextIn, +64 if the last block, +128 at the end of a block, +256 after
  /// a block header.
  int dataType = 0;

  // ---- inflate_state ----
  int mode = _head; // current inflate mode
  int last = 0; // true if processing last block
  int wrap = 0; // raw: 0
  int total = 0; // protected copy of output count

  // sliding window
  int wbits = 0; // log base 2 of requested window size
  int wsize = 0; // window size or zero if not using window
  int whave = 0; // valid bytes in the window
  int wnext = 0; // window write index
  Uint8List? window; // allocated sliding window, if needed

  // bit accumulator
  int hold = 0; // input bit accumulator
  int bits = 0; // number of bits in "in"

  // for string and stored block copying
  int length = 0; // literal or length of data to copy
  int offset = 0; // distance back to copy string from

  // for table and code decoding
  int extra = 0; // extra bits needed

  // fixed and dynamic code tables
  Uint32List lencodeTab = _fixed; // starting table for length/literal codes
  int lencode = 0;
  Uint32List distcodeTab = _fixed; // starting table for distance codes
  int distcode = 0;
  int lenbits = 0; // index bits for lencode
  int distbits = 0; // index bits for distcode

  // dynamic table building
  int ncode = 0; // number of code length code lengths
  int nlen = 0; // number of length code lengths
  int ndist = 0; // number of distance code lengths
  int have = 0; // number of code lengths in lens[]
  int next = 0; // next available space in codes[]
  final Uint16List lens = Uint16List(320); // temporary code lengths
  final Uint16List work = Uint16List(288); // work area for table building
  final Uint32List codes = Uint32List(enough); // space for code tables
  int sane = 1; // if false, allow invalid distance too far
  int back = -1; // bits back of last unprocessed length/lit
  int was = 0; // initial length of match

  final InflateTableResult _tr = InflateTableResult();

  /// inflateInit2_ with a negative windowBits (raw inflate). [windowBits]
  /// is 8..15.
  InflateState({int windowBits = zMaxWbits}) {
    _inflateReset2(windowBits);
  }

  // inflateResetKeep
  void _inflateResetKeep() {
    totalIn = totalOut = total = 0;
    msg = null;
    mode = _head;
    last = 0;
    hold = 0;
    bits = 0;
    lencodeTab = distcodeTab = codes;
    lencode = distcode = next = 0;
    sane = 1;
    back = -1;
  }

  /// inflateReset
  void inflateReset() {
    wsize = 0;
    whave = 0;
    wnext = 0;
    _inflateResetKeep();
  }

  // inflateReset2
  void _inflateReset2(int windowBits) {
    // set number of window bits, free window if different
    if (windowBits < 8 || windowBits > 15) {
      throw ArgumentError('inflate: invalid window size');
    }
    if (window != null && wbits != windowBits) window = null;

    // update state and reset the rest of it
    wrap = 0;
    wbits = windowBits;
    inflateReset();
  }

  // fixedtables
  void _fixedtables() {
    lencodeTab = _fixed;
    lencode = 0;
    lenbits = 9;
    distcodeTab = _fixed;
    distcode = 512;
    distbits = 5;
  }

  // updatewindow: updates the window with the last wsize (normally 32K)
  // bytes written before returning. If window does not exist yet, create
  // it.
  void _updatewindow(Uint8List endBuf, int end, int copy) {
    // if it hasn't been done already, allocate space for the window
    final w = window ??= Uint8List(1 << wbits);

    // if window not in use yet, initialize
    if (wsize == 0) {
      wsize = 1 << wbits;
      wnext = 0;
      whave = 0;
    }

    // copy state.wsize or less output bytes into the circular window
    if (copy >= wsize) {
      w.setRange(0, wsize, endBuf, end - wsize);
      wnext = 0;
      whave = wsize;
    } else {
      var dist = wsize - wnext;
      if (dist > copy) dist = copy;
      w.setRange(wnext, wnext + dist, endBuf, end - copy);
      copy -= dist;
      if (copy != 0) {
        w.setRange(0, copy, endBuf, end - copy);
        wnext = copy;
        whave = wsize;
      } else {
        wnext += dist;
        if (wnext == wsize) wnext = 0;
        if (whave < wsize) whave += dist;
      }
    }
  }

  /// inflate: decompresses as much data as possible from nextIn to
  /// nextOut. Returns a [ZResult] value: Z_STREAM_END at the end of the
  /// deflate stream, Z_DATA_ERROR for invalid data (see [msg]),
  /// Z_BUF_ERROR when no progress was possible (or with Z_FINISH before the
  /// end).
  int inflate(int flush) {
    Uint8List inBuf; // next input
    int next; // index of next input
    Uint8List outBuf; // next output
    int put; // index of next output
    int have, left; // available input and output
    int hold; // bit buffer
    int bits; // bits in bit buffer
    int inAvail, out; // save starting available input and output
    int copy; // number of stored or match bytes to copy
    Uint8List from; // where to copy match bytes from
    int fromPos;
    int here; // current decoding table entry
    int lastCode; // parent table entry
    int hereBits, hereOp, hereVal;
    int len; // length to copy for repeats, bits to drop
    var ret = ZResult.ok; // return code

    if (mode == _type) mode = _typedo; // skip check
    // LOAD()
    outBuf = nextOut;
    put = nextOutPos;
    left = availOut;
    inBuf = nextIn;
    next = nextInPos;
    have = availIn;
    hold = this.hold;
    bits = this.bits;

    inAvail = have;
    out = left;

    infLeave:
    for (;;) {
      switch (mode) {
        case _head:
          // raw inflate (state.wrap == 0)
          mode = _typedo;
        case _type:
        case _typedo:
          if (mode == _type && (flush == ZFlush.block || flush == ZFlush.trees)) {
            break infLeave;
          }
          if (last != 0) {
            // BYTEBITS()
            hold >>= bits & 7;
            bits -= bits & 7;
            mode = _check;
            break;
          }
          // NEEDBITS(3)
          while (bits < 3) {
            if (have == 0) break infLeave;
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          last = hold & 1;
          hold >>= 1;
          bits -= 1;
          switch (hold & 3) {
            case 0: // stored block
              mode = _stored;
            case 1: // fixed block
              _fixedtables();
              mode = _len_; // decode codes
              if (flush == ZFlush.trees) {
                hold >>= 2;
                bits -= 2;
                break infLeave;
              }
            case 2: // dynamic block
              mode = _table;
            case 3:
              msg = 'invalid block type';
              mode = _bad;
          }
          hold >>= 2;
          bits -= 2;
        case _stored:
          // BYTEBITS(): go to byte boundary
          hold >>= bits & 7;
          bits -= bits & 7;
          // NEEDBITS(32)
          while (bits < 32) {
            if (have == 0) break infLeave;
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          if ((hold & 0xffff) != ((hold >> 16) ^ 0xffff)) {
            msg = 'invalid stored block lengths';
            mode = _bad;
            break;
          }
          length = hold & 0xffff;
          hold = 0;
          bits = 0;
          mode = _copy_;
          if (flush == ZFlush.trees) break infLeave;
        case _copy_:
          mode = _copy;
        case _copy:
          copy = length;
          if (copy != 0) {
            if (copy > have) copy = have;
            if (copy > left) copy = left;
            if (copy == 0) break infLeave;
            outBuf.setRange(put, put + copy, inBuf, next);
            have -= copy;
            next += copy;
            left -= copy;
            put += copy;
            length -= copy;
            break;
          }
          mode = _type;
        case _table:
          // NEEDBITS(14)
          while (bits < 14) {
            if (have == 0) break infLeave;
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          nlen = (hold & 0x1f) + 257;
          hold >>= 5;
          bits -= 5;
          ndist = (hold & 0x1f) + 1;
          hold >>= 5;
          bits -= 5;
          ncode = (hold & 0xf) + 4;
          hold >>= 4;
          bits -= 4;
          if (nlen > 286 || ndist > 30) {
            msg = 'too many length or distance symbols';
            mode = _bad;
            break;
          }
          this.have = 0;
          mode = _lenlens;
        case _lenlens:
          while (this.have < ncode) {
            // NEEDBITS(3)
            while (bits < 3) {
              if (have == 0) break infLeave;
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            lens[_order[this.have++]] = hold & 7;
            hold >>= 3;
            bits -= 3;
          }
          while (this.have < 19) {
            lens[_order[this.have++]] = 0;
          }
          this.next = 0;
          lencodeTab = codes;
          lencode = 0;
          inflateTable(codesType, lens, 0, 19, codes, 0, 7, work, _tr);
          lenbits = _tr.bits;
          this.next = _tr.next;
          if (_tr.ret != 0) {
            msg = 'invalid code lengths set';
            mode = _bad;
            break;
          }
          this.have = 0;
          mode = _codelens;
        case _codelens:
          while (this.have < nlen + ndist) {
            for (;;) {
              here = lencodeTab[lencode + (hold & ((1 << lenbits) - 1))];
              if (((here >> 8) & 0xff) <= bits) break;
              // PULLBYTE()
              if (have == 0) break infLeave;
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            hereBits = (here >> 8) & 0xff;
            hereVal = here >> 16;
            if (hereVal < 16) {
              hold >>= hereBits;
              bits -= hereBits;
              lens[this.have++] = hereVal;
            } else {
              if (hereVal == 16) {
                // NEEDBITS(here.bits + 2)
                while (bits < hereBits + 2) {
                  if (have == 0) break infLeave;
                  have--;
                  hold += inBuf[next++] << bits;
                  bits += 8;
                }
                hold >>= hereBits;
                bits -= hereBits;
                if (this.have == 0) {
                  msg = 'invalid bit length repeat';
                  mode = _bad;
                  break;
                }
                len = lens[this.have - 1];
                copy = 3 + (hold & 3);
                hold >>= 2;
                bits -= 2;
              } else if (hereVal == 17) {
                // NEEDBITS(here.bits + 3)
                while (bits < hereBits + 3) {
                  if (have == 0) break infLeave;
                  have--;
                  hold += inBuf[next++] << bits;
                  bits += 8;
                }
                hold >>= hereBits;
                bits -= hereBits;
                len = 0;
                copy = 3 + (hold & 7);
                hold >>= 3;
                bits -= 3;
              } else {
                // NEEDBITS(here.bits + 7)
                while (bits < hereBits + 7) {
                  if (have == 0) break infLeave;
                  have--;
                  hold += inBuf[next++] << bits;
                  bits += 8;
                }
                hold >>= hereBits;
                bits -= hereBits;
                len = 0;
                copy = 11 + (hold & 0x7f);
                hold >>= 7;
                bits -= 7;
              }
              if (this.have + copy > nlen + ndist) {
                msg = 'invalid bit length repeat';
                mode = _bad;
                break;
              }
              while (copy-- != 0) {
                lens[this.have++] = len;
              }
            }
          }

          // handle error breaks in while
          if (mode == _bad) break;

          // check for end-of-block code (better have one)
          if (lens[256] == 0) {
            msg = 'invalid code -- missing end-of-block';
            mode = _bad;
            break;
          }

          // build code tables. Note: do not change the lenbits or distbits
          // values here (9 and 6) without reading the comments in
          // inftrees.h concerning the ENOUGH constants, which depend on
          // those values
          this.next = 0;
          lencodeTab = codes;
          lencode = 0;
          inflateTable(lensType, lens, 0, nlen, codes, 0, 9, work, _tr);
          lenbits = _tr.bits;
          this.next = _tr.next;
          if (_tr.ret != 0) {
            msg = 'invalid literal/lengths set';
            mode = _bad;
            break;
          }
          distcodeTab = codes;
          distcode = this.next;
          inflateTable(
              distsType, lens, nlen, ndist, codes, this.next, 6, work, _tr);
          distbits = _tr.bits;
          this.next = _tr.next;
          if (_tr.ret != 0) {
            msg = 'invalid distances set';
            mode = _bad;
            break;
          }
          mode = _len_;
          if (flush == ZFlush.trees) break infLeave;
        case _len_:
          mode = _len;
        case _len:
          if (have >= 6 && left >= 258) {
            // RESTORE()
            nextOutPos = put;
            availOut = left;
            nextInPos = next;
            availIn = have;
            this.hold = hold;
            this.bits = bits;
            _inflateFast(out);
            // LOAD()
            put = nextOutPos;
            left = availOut;
            next = nextInPos;
            have = availIn;
            hold = this.hold;
            bits = this.bits;
            if (mode == _type) back = -1;
            break;
          }
          back = 0;
          for (;;) {
            here = lencodeTab[lencode + (hold & ((1 << lenbits) - 1))];
            if (((here >> 8) & 0xff) <= bits) break;
            // PULLBYTE()
            if (have == 0) break infLeave;
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          hereOp = here & 0xff;
          if (hereOp != 0 && (hereOp & 0xf0) == 0) {
            lastCode = here;
            final lastBits = (lastCode >> 8) & 0xff;
            final lastOp = lastCode & 0xff;
            final lastVal = lastCode >> 16;
            for (;;) {
              here = lencodeTab[lencode +
                  lastVal +
                  ((hold & ((1 << (lastBits + lastOp)) - 1)) >> lastBits)];
              if (lastBits + ((here >> 8) & 0xff) <= bits) break;
              // PULLBYTE()
              if (have == 0) break infLeave;
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            hold >>= lastBits;
            bits -= lastBits;
            back += lastBits;
          }
          hereBits = (here >> 8) & 0xff;
          hereOp = here & 0xff;
          hold >>= hereBits;
          bits -= hereBits;
          back += hereBits;
          length = here >> 16;
          if (hereOp == 0) {
            mode = _lit;
            break;
          }
          if ((hereOp & 32) != 0) {
            back = -1;
            mode = _type;
            break;
          }
          if ((hereOp & 64) != 0) {
            msg = 'invalid literal/length code';
            mode = _bad;
            break;
          }
          extra = hereOp & 15;
          mode = _lenext;
        case _lenext:
          if (extra != 0) {
            // NEEDBITS(state.extra)
            while (bits < extra) {
              if (have == 0) break infLeave;
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            length += hold & ((1 << extra) - 1);
            hold >>= extra;
            bits -= extra;
            back += extra;
          }
          was = length;
          mode = _dist;
        case _dist:
          for (;;) {
            here = distcodeTab[distcode + (hold & ((1 << distbits) - 1))];
            if (((here >> 8) & 0xff) <= bits) break;
            // PULLBYTE()
            if (have == 0) break infLeave;
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          if ((here & 0xf0) == 0) {
            lastCode = here;
            final lastBits = (lastCode >> 8) & 0xff;
            final lastOp = lastCode & 0xff;
            final lastVal = lastCode >> 16;
            for (;;) {
              here = distcodeTab[distcode +
                  lastVal +
                  ((hold & ((1 << (lastBits + lastOp)) - 1)) >> lastBits)];
              if (lastBits + ((here >> 8) & 0xff) <= bits) break;
              // PULLBYTE()
              if (have == 0) break infLeave;
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            hold >>= lastBits;
            bits -= lastBits;
            back += lastBits;
          }
          hereBits = (here >> 8) & 0xff;
          hereOp = here & 0xff;
          hold >>= hereBits;
          bits -= hereBits;
          back += hereBits;
          if ((hereOp & 64) != 0) {
            msg = 'invalid distance code';
            mode = _bad;
            break;
          }
          offset = here >> 16;
          extra = hereOp & 15;
          mode = _distext;
        case _distext:
          if (extra != 0) {
            // NEEDBITS(state.extra)
            while (bits < extra) {
              if (have == 0) break infLeave;
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            offset += hold & ((1 << extra) - 1);
            hold >>= extra;
            bits -= extra;
            back += extra;
          }
          mode = _match;
        case _match:
          if (left == 0) break infLeave;
          copy = out - left;
          if (offset > copy) {
            // copy from window
            copy = offset - copy;
            if (copy > whave) {
              if (sane != 0) {
                msg = 'invalid distance too far back';
                mode = _bad;
                break;
              }
            }
            from = window!;
            if (copy > wnext) {
              copy -= wnext;
              fromPos = wsize - copy;
            } else {
              fromPos = wnext - copy;
            }
            if (copy > length) copy = length;
          } else {
            // copy from output
            from = outBuf;
            fromPos = put - offset;
            copy = length;
          }
          if (copy > left) copy = left;
          left -= copy;
          length -= copy;
          do {
            outBuf[put++] = from[fromPos++];
          } while (--copy != 0);
          if (length == 0) mode = _len;
        case _lit:
          if (left == 0) break infLeave;
          outBuf[put++] = length;
          left--;
          mode = _len;
        case _check:
          // raw inflate: no check value
          mode = _length;
        case _length:
          mode = _done;
        case _done:
          ret = ZResult.streamEnd;
          break infLeave;
        case _bad:
          ret = ZResult.dataError;
          break infLeave;
        case _mem:
          return ZResult.memError;
        case _sync:
        default:
          return ZResult.streamError;
      }
    }

    // inf_leave: Return from inflate(), updating the total counts. If
    // there was no progress during the inflate() call, return a buffer
    // error. Call updatewindow() to create and/or update the window state.
    // RESTORE()
    nextOutPos = put;
    availOut = left;
    nextInPos = next;
    availIn = have;
    this.hold = hold;
    this.bits = bits;

    if (wsize != 0 ||
        (out != availOut &&
            mode < _bad &&
            (mode < _check || flush != ZFlush.finish))) {
      _updatewindow(nextOut, nextOutPos, out - availOut);
    }
    inAvail -= availIn;
    out -= availOut;
    totalIn += inAvail;
    totalOut += out;
    total += out;
    dataType = this.bits +
        (last != 0 ? 64 : 0) +
        (mode == _type ? 128 : 0) +
        (mode == _len_ || mode == _copy_ ? 256 : 0);
    if (((inAvail == 0 && out == 0) || flush == ZFlush.finish) &&
        ret == ZResult.ok) {
      ret = ZResult.bufError;
    }
    return ret;
  }

  /// True when the end of the deflate stream was reached (mode DONE).
  bool get isDone => mode == _done;

  // inflate_fast (inffast.c): decodes literal, length, and distance codes
  // and writes out the resulting literal and match bytes until either not
  // enough input or output is available, an end-of-block is encountered,
  // or a data error is encountered. On entry availIn >= 6, availOut >= 258
  // and the mode is LEN. [start] is inflate()'s starting value for
  // availOut.
  void _inflateFast(int start) {
    final inBuf = nextIn;
    var inp = nextInPos; // local strm.next_in
    final last = inp + (availIn - 5); // have enough input while in < last
    final out = nextOut;
    var op_ = nextOutPos; // local strm.next_out
    final beg = op_ - (start - availOut); // inflate()'s initial next_out
    final end = op_ + (availOut - 257); // while out < end, enough space
    final wsize = this.wsize; // window size or zero if not using window
    final whave = this.whave; // valid bytes in the window
    final wnext = this.wnext; // window write index
    final window = this.window; // allocated sliding window, if wsize != 0
    var hold = this.hold; // local strm.hold
    var bits = this.bits; // local strm.bits
    final lcodeTab = lencodeTab; // local strm.lencode
    final lcode = lencode;
    final dcodeTab = distcodeTab; // local strm.distcode
    final dcode = distcode;
    final lmask = (1 << lenbits) - 1; // mask for first level of length codes
    final dmask = (1 << distbits) - 1; // mask for first level of distances
    int here; // retrieved table entry
    int op; // code bits, operation, extra bits, or window position
    int len; // match length, unused bytes
    int dist; // match distance
    int from; // where to copy match from

    // decode literals and length/distances until end-of-block or not enough
    // input data or output space
    outer:
    do {
      if (bits < 15) {
        hold += inBuf[inp++] << bits;
        bits += 8;
        hold += inBuf[inp++] << bits;
        bits += 8;
      }
      here = lcodeTab[lcode + (hold & lmask)];
      // dolen:
      for (;;) {
        op = (here >> 8) & 0xff;
        hold >>= op;
        bits -= op;
        op = here & 0xff;
        if (op == 0) {
          // literal
          out[op_++] = here >> 16;
          continue outer;
        }
        if ((op & 16) != 0) {
          // length base
          len = here >> 16;
          op &= 15; // number of extra bits
          if (op != 0) {
            if (bits < op) {
              hold += inBuf[inp++] << bits;
              bits += 8;
            }
            len += hold & ((1 << op) - 1);
            hold >>= op;
            bits -= op;
          }
          if (bits < 15) {
            hold += inBuf[inp++] << bits;
            bits += 8;
            hold += inBuf[inp++] << bits;
            bits += 8;
          }
          here = dcodeTab[dcode + (hold & dmask)];
          // dodist:
          for (;;) {
            op = (here >> 8) & 0xff;
            hold >>= op;
            bits -= op;
            op = here & 0xff;
            if ((op & 16) != 0) {
              // distance base
              dist = here >> 16;
              op &= 15; // number of extra bits
              if (bits < op) {
                hold += inBuf[inp++] << bits;
                bits += 8;
                if (bits < op) {
                  hold += inBuf[inp++] << bits;
                  bits += 8;
                }
              }
              dist += hold & ((1 << op) - 1);
              hold >>= op;
              bits -= op;
              op = op_ - beg; // max distance in output
              if (dist > op) {
                // see if copy from window
                op = dist - op; // distance back in window
                if (op > whave) {
                  if (sane != 0) {
                    msg = 'invalid distance too far back';
                    mode = _bad;
                    break outer;
                  }
                }
                final win = window!;
                if (wnext == 0) {
                  // very common case
                  from = wsize - op;
                  if (op < len) {
                    // some from window
                    len -= op;
                    do {
                      out[op_++] = win[from++];
                    } while (--op != 0);
                    from = op_ - dist; // rest from output
                    _copyFromOut(out, op_, from, len);
                    op_ += len;
                    continue outer;
                  }
                  do {
                    out[op_++] = win[from++];
                  } while (--len != 0);
                  continue outer;
                } else if (wnext < op) {
                  // wrap around window
                  from = wsize + wnext - op;
                  op -= wnext;
                  if (op < len) {
                    // some from end of window
                    len -= op;
                    do {
                      out[op_++] = win[from++];
                    } while (--op != 0);
                    from = 0;
                    if (wnext < len) {
                      // some from start of window
                      op = wnext;
                      len -= op;
                      do {
                        out[op_++] = win[from++];
                      } while (--op != 0);
                      from = op_ - dist; // rest from output
                      _copyFromOut(out, op_, from, len);
                      op_ += len;
                      continue outer;
                    }
                  }
                  do {
                    out[op_++] = win[from++];
                  } while (--len != 0);
                  continue outer;
                } else {
                  // contiguous in window
                  from = wnext - op;
                  if (op < len) {
                    // some from window
                    len -= op;
                    do {
                      out[op_++] = win[from++];
                    } while (--op != 0);
                    from = op_ - dist; // rest from output
                    _copyFromOut(out, op_, from, len);
                    op_ += len;
                    continue outer;
                  }
                  do {
                    out[op_++] = win[from++];
                  } while (--len != 0);
                  continue outer;
                }
              } else {
                // copy direct from output
                _copyFromOut(out, op_, op_ - dist, len);
                op_ += len;
                continue outer;
              }
            } else if ((op & 64) == 0) {
              // 2nd level distance code
              here = dcodeTab[dcode + (here >> 16) + (hold & ((1 << op) - 1))];
              continue; // goto dodist
            } else {
              msg = 'invalid distance code';
              mode = _bad;
              break outer;
            }
          }
        } else if ((op & 64) == 0) {
          // 2nd level length code
          here = lcodeTab[lcode + (here >> 16) + (hold & ((1 << op) - 1))];
          continue; // goto dolen
        } else if ((op & 32) != 0) {
          // end-of-block
          mode = _type;
          break outer;
        } else {
          msg = 'invalid literal/length code';
          mode = _bad;
          break outer;
        }
      }
    } while (inp < last && op_ < end);

    // return unused bytes (on entry, bits < 8, so in won't go too far back)
    len = bits >> 3;
    inp -= len;
    bits -= len << 3;
    hold &= (1 << bits) - 1;

    // update state and return
    nextInPos = inp;
    nextOutPos = op_;
    availIn = inp < last ? 5 + (last - inp) : 5 - (inp - last);
    availOut = op_ < end ? 257 + (end - op_) : 257 - (op_ - end);
    this.hold = hold;
    this.bits = bits;
  }
}

// The match copy of inflate_fast from earlier output (the "rest from
// output" and "copy direct from output" loops). The copy runs forward one
// byte at a time when the source and the destination overlap, as in C; a
// non overlapping copy is one setRange.
@pragma('vm:prefer-inline')
void _copyFromOut(Uint8List out, int to, int from, int len) {
  if (to - from >= len) {
    out.setRange(to, to + len, out, from);
  } else {
    final e = to + len;
    while (to < e) {
      out[to++] = out[from++];
    }
  }
}
