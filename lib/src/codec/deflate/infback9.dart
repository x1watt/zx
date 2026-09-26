// Deflate64 decoding: port of contrib/infback9 of zlib 1.3.1 (infback9.c,
// inflate9.h; Mark Adler, zlib license, see LICENSE). The tables come from
// inflateTable9 (inftree9.c) in inftrees.dart; the fixed tables are built
// at first use as makefixed9() builds inffix9.h.
//
// inflateBack9() is a push decoder: it calls in() for input and out() each
// time its 64K window is full. The port keeps its structure and window, but
// can return where it would call out() (ROOM with a full window) and resume
// there, so that a pull stream can hand out the window: [Inflate9.decode]
// returns [Inflate9.windowFull], the caller takes the whole window, and the
// next call continues. For that the literal, the match copy and the stored
// copy got their own modes (LIT, MATCH, COPY, as in inflate.c). Input is
// pulled from an [InStream] where infback9 calls in().

import 'dart:typed_data';

import '../../io/streams.dart';
import 'inftrees.dart';

const int _wsize = 65536; // WSIZE

// inflate_mode (inflate9.h), plus the resume points of this port
const int _type = 0; // i: waiting for type bits, including last-flag bit
const int _stored = 1; // i: waiting for stored size (length and complement)
const int _table = 2; // i: waiting for dynamic block table lengths
const int _len = 3; // i: waiting for length/lit code
const int _done = 4; // finished check, done
const int _bad = 5; // got a data error
const int _copy = 6; // o: copying a stored block (this port)
const int _lit = 7; // o: writing a literal (this port)
const int _match = 8; // o: copying a match (this port)

// permutation of code lengths
const List<int> _order = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 //
];

/// lenfix at 0 and distfix at 512 (makefixed9).
final Uint32List _fixed9 = _buildFixed9();

// makefixed9
Uint32List _buildFixed9() {
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
  inflateTable9(lensType, lens, 0, 288, fixed, 0, 9, work, r);

  // distance table
  sym = 0;
  while (sym < 32) {
    lens[sym++] = 5;
  }
  inflateTable9(distsType, lens, 0, 32, fixed, r.next, 5, work, r);
  return fixed;
}

/// The Deflate64 decoder: inflateBack9() and its struct inflate_state.
class Inflate9 {
  /// [decode] results.
  static const int windowFull = 0; // ROOM(): out() with the whole window
  static const int streamEnd = 1; // Z_STREAM_END
  static const int dataError = -3; // Z_DATA_ERROR
  static const int bufError = -5; // Z_BUF_ERROR: in() returned no input

  final InStream _input;

  /// The input buffer (the buffer in() hands out).
  final Uint8List inBuf;

  /// next input byte and available input (strm.next_in, avail_in).
  int next = 0;
  int have = 0;

  /// Total bytes returned by in().
  int inTotal = 0;

  /// error message for Z_DATA_ERROR (strm.msg)
  String? msg;

  /// The 64K window, which is also the output buffer.
  final Uint8List window = Uint8List(_wsize);

  int _mode = _type; // current inflate mode
  int _lastblock = 0; // true if processing last block
  int _wrap = 0; // true if the window has wrapped
  int put = 0; // next output
  int left = _wsize; // available output
  int _hold = 0; // bit buffer
  int _bits = 0; // bits in bit buffer
  int _length = 0; // literal or length of data to copy
  int _offset = 0; // distance back to copy string from
  Uint32List _lencodeTab = _fixed9; // starting table for length/literal
  int _lencode = 0;
  Uint32List _distcodeTab = _fixed9; // starting table for distance codes
  int _distcode = 0;
  int _lenbits = 0; // index bits for lencode
  int _distbits = 0; // index bits for distcode

  // dynamic table building
  int _ncode = 0; // number of code length code lengths
  int _nlen = 0; // number of length code lengths
  int _ndist = 0; // number of distance code lengths
  int _have = 0; // number of code lengths in lens[]
  final Uint16List _lens = Uint16List(320); // temporary code lengths
  final Uint16List _work = Uint16List(288); // work area for tables
  final Uint32List _codes = Uint32List(enough9); // space for code tables
  final InflateTableResult _tr = InflateTableResult();

  /// inflateBack9Init_. [input] is read in chunks of [inBufSize] bytes.
  Inflate9(this._input, {int inBufSize = 1 << 16})
      : inBuf = Uint8List(inBufSize);

  /// True after the last block (the output is complete).
  bool get isDone => _mode == _done;

  // in(): refills the input buffer. Returns the number of bytes, 0 at the
  // end of the input.
  int _in() {
    next = 0;
    final n = _input.read(inBuf, 0, inBuf.length);
    inTotal += n;
    return n;
  }

  /// inflateBack9: decodes until the window is full ([windowFull]: the
  /// caller takes window[0 .. 65536) and calls again), or the end of the
  /// stream ([streamEnd]: the output is window[0 .. put)), or an error.
  int decode() {
    // Load the state in locals (the locals of inflateBack9).
    final inBuf = this.inBuf;
    var next = this.next;
    var have = this.have;
    final window = this.window;
    var put = this.put;
    var left = this.left;
    var hold = _hold;
    var bits = _bits;
    var mode = _mode;
    var length = _length;
    var offset = _offset;
    int copy;
    int from;
    int here; // current decoding table entry
    int hereBits, hereOp, hereVal;
    int len; // length to copy for repeats, bits to drop
    int extra; // extra bits needed
    int ret;

    infLeave:
    for (;;) {
      switch (mode) {
        case _type:
          // determine and dispatch block type
          if (_lastblock != 0) {
            // BYTEBITS()
            hold >>= bits & 7;
            bits -= bits & 7;
            mode = _done;
            break;
          }
          // NEEDBITS(3)
          while (bits < 3) {
            if (have == 0) {
              have = _in();
              next = 0;
              if (have == 0) {
                ret = bufError;
                break infLeave;
              }
            }
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          _lastblock = hold & 1;
          hold >>= 1;
          bits -= 1;
          switch (hold & 3) {
            case 0: // stored block
              mode = _stored;
            case 1: // fixed block
              _lencodeTab = _fixed9;
              _lencode = 0;
              _lenbits = 9;
              _distcodeTab = _fixed9;
              _distcode = 512;
              _distbits = 5;
              mode = _len; // decode codes
            case 2: // dynamic block
              mode = _table;
            case 3:
              msg = 'invalid block type';
              mode = _bad;
          }
          hold >>= 2;
          bits -= 2;
        case _stored:
          // get and verify stored block length
          // BYTEBITS(): go to byte boundary
          hold >>= bits & 7;
          bits -= bits & 7;
          // NEEDBITS(32)
          while (bits < 32) {
            if (have == 0) {
              have = _in();
              next = 0;
              if (have == 0) {
                ret = bufError;
                break infLeave;
              }
            }
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
          // INITBITS()
          hold = 0;
          bits = 0;
          mode = _copy;
        case _copy:
          // copy stored block from input to output
          while (length != 0) {
            copy = length;
            // PULL()
            if (have == 0) {
              have = _in();
              next = 0;
              if (have == 0) {
                ret = bufError;
                break infLeave;
              }
            }
            // ROOM()
            if (left == 0) {
              if (put != 0) {
                ret = windowFull;
                break infLeave;
              }
              put = 0;
              left = _wsize;
              _wrap = 1;
            }
            if (copy > have) copy = have;
            if (copy > left) copy = left;
            window.setRange(put, put + copy, inBuf, next);
            have -= copy;
            next += copy;
            left -= copy;
            put += copy;
            length -= copy;
          }
          mode = _type;
        case _table:
          // get dynamic table entries descriptor
          // NEEDBITS(14)
          while (bits < 14) {
            if (have == 0) {
              have = _in();
              next = 0;
              if (have == 0) {
                ret = bufError;
                break infLeave;
              }
            }
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          _nlen = (hold & 0x1f) + 257;
          hold >>= 5;
          bits -= 5;
          _ndist = (hold & 0x1f) + 1;
          hold >>= 5;
          bits -= 5;
          _ncode = (hold & 0xf) + 4;
          hold >>= 4;
          bits -= 4;
          if (_nlen > 286) {
            msg = 'too many length symbols';
            mode = _bad;
            break;
          }

          // get code length code lengths (not a typo)
          _have = 0;
          while (_have < _ncode) {
            // NEEDBITS(3)
            while (bits < 3) {
              if (have == 0) {
                have = _in();
                next = 0;
                if (have == 0) {
                  ret = bufError;
                  break infLeave;
                }
              }
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            _lens[_order[_have++]] = hold & 7;
            hold >>= 3;
            bits -= 3;
          }
          while (_have < 19) {
            _lens[_order[_have++]] = 0;
          }
          _lencodeTab = _codes;
          _lencode = 0;
          inflateTable9(codesType, _lens, 0, 19, _codes, 0, 7, _work, _tr);
          _lenbits = _tr.bits;
          if (_tr.ret != 0) {
            msg = 'invalid code lengths set';
            mode = _bad;
            break;
          }

          // get length and distance code code lengths
          _have = 0;
          while (_have < _nlen + _ndist) {
            for (;;) {
              here = _lencodeTab[_lencode + (hold & ((1 << _lenbits) - 1))];
              if (((here >> 8) & 0xff) <= bits) break;
              // PULLBYTE()
              if (have == 0) {
                have = _in();
                next = 0;
                if (have == 0) {
                  ret = bufError;
                  break infLeave;
                }
              }
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            hereBits = (here >> 8) & 0xff;
            hereVal = here >> 16;
            if (hereVal < 16) {
              // NEEDBITS(here.bits): already there
              hold >>= hereBits;
              bits -= hereBits;
              _lens[_have++] = hereVal;
            } else {
              var need = hereBits + 7;
              if (hereVal == 16) {
                need = hereBits + 2;
              } else if (hereVal == 17) {
                need = hereBits + 3;
              }
              // NEEDBITS(need)
              while (bits < need) {
                if (have == 0) {
                  have = _in();
                  next = 0;
                  if (have == 0) {
                    ret = bufError;
                    break infLeave;
                  }
                }
                have--;
                hold += inBuf[next++] << bits;
                bits += 8;
              }
              hold >>= hereBits;
              bits -= hereBits;
              if (hereVal == 16) {
                if (_have == 0) {
                  msg = 'invalid bit length repeat';
                  mode = _bad;
                  break;
                }
                len = _lens[_have - 1];
                copy = 3 + (hold & 3);
                hold >>= 2;
                bits -= 2;
              } else if (hereVal == 17) {
                len = 0;
                copy = 3 + (hold & 7);
                hold >>= 3;
                bits -= 3;
              } else {
                len = 0;
                copy = 11 + (hold & 0x7f);
                hold >>= 7;
                bits -= 7;
              }
              if (_have + copy > _nlen + _ndist) {
                msg = 'invalid bit length repeat';
                mode = _bad;
                break;
              }
              while (copy-- != 0) {
                _lens[_have++] = len;
              }
            }
          }

          // handle error breaks in while
          if (mode == _bad) break;

          // check for end-of-block code (better have one)
          if (_lens[256] == 0) {
            msg = 'invalid code -- missing end-of-block';
            mode = _bad;
            break;
          }

          // build code tables. Note: do not change the lenbits or distbits
          // values here (9 and 6) without reading the comments in
          // inftree9.h concerning the ENOUGH constants, which depend on
          // those values
          _lencodeTab = _codes;
          _lencode = 0;
          inflateTable9(lensType, _lens, 0, _nlen, _codes, 0, 9, _work, _tr);
          _lenbits = _tr.bits;
          if (_tr.ret != 0) {
            msg = 'invalid literal/lengths set';
            mode = _bad;
            break;
          }
          _distcodeTab = _codes;
          _distcode = _tr.next;
          inflateTable9(distsType, _lens, _nlen, _ndist, _codes, _tr.next, 6,
              _work, _tr);
          _distbits = _tr.bits;
          if (_tr.ret != 0) {
            msg = 'invalid distances set';
            mode = _bad;
            break;
          }
          mode = _len;
        case _len:
          // get a literal, length, or end-of-block code
          final lcodeTab = _lencodeTab;
          final lcode = _lencode;
          final lmask = (1 << _lenbits) - 1;
          for (;;) {
            here = lcodeTab[lcode + (hold & lmask)];
            if (((here >> 8) & 0xff) <= bits) break;
            // PULLBYTE()
            if (have == 0) {
              have = _in();
              next = 0;
              if (have == 0) {
                ret = bufError;
                break infLeave;
              }
            }
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          hereOp = here & 0xff;
          if (hereOp != 0 && (hereOp & 0xf0) == 0) {
            final lastBits = (here >> 8) & 0xff;
            final lastVal = here >> 16;
            final m = (1 << (lastBits + hereOp)) - 1;
            for (;;) {
              here = lcodeTab[lcode + lastVal + ((hold & m) >> lastBits)];
              if (lastBits + ((here >> 8) & 0xff) <= bits) break;
              // PULLBYTE()
              if (have == 0) {
                have = _in();
                next = 0;
                if (have == 0) {
                  ret = bufError;
                  break infLeave;
                }
              }
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            hold >>= lastBits;
            bits -= lastBits;
          }
          hereBits = (here >> 8) & 0xff;
          hereOp = here & 0xff;
          hold >>= hereBits;
          bits -= hereBits;
          length = here >> 16;

          // process literal
          if (hereOp == 0) {
            mode = _lit;
            break;
          }

          // process end of block
          if ((hereOp & 32) != 0) {
            mode = _type;
            break;
          }

          // invalid code
          if ((hereOp & 64) != 0) {
            msg = 'invalid literal/length code';
            mode = _bad;
            break;
          }

          // length code: get extra bits, if any
          extra = hereOp & 31;
          if (extra != 0) {
            // NEEDBITS(extra)
            while (bits < extra) {
              if (have == 0) {
                have = _in();
                next = 0;
                if (have == 0) {
                  ret = bufError;
                  break infLeave;
                }
              }
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            length += hold & ((1 << extra) - 1);
            hold >>= extra;
            bits -= extra;
          }

          // get distance code
          final dcodeTab = _distcodeTab;
          final dcode = _distcode;
          final dmask = (1 << _distbits) - 1;
          for (;;) {
            here = dcodeTab[dcode + (hold & dmask)];
            if (((here >> 8) & 0xff) <= bits) break;
            // PULLBYTE()
            if (have == 0) {
              have = _in();
              next = 0;
              if (have == 0) {
                ret = bufError;
                break infLeave;
              }
            }
            have--;
            hold += inBuf[next++] << bits;
            bits += 8;
          }
          hereOp = here & 0xff;
          if ((hereOp & 0xf0) == 0) {
            final lastBits = (here >> 8) & 0xff;
            final lastVal = here >> 16;
            final m = (1 << (lastBits + hereOp)) - 1;
            for (;;) {
              here = dcodeTab[dcode + lastVal + ((hold & m) >> lastBits)];
              if (lastBits + ((here >> 8) & 0xff) <= bits) break;
              // PULLBYTE()
              if (have == 0) {
                have = _in();
                next = 0;
                if (have == 0) {
                  ret = bufError;
                  break infLeave;
                }
              }
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            hold >>= lastBits;
            bits -= lastBits;
          }
          hereBits = (here >> 8) & 0xff;
          hereOp = here & 0xff;
          hold >>= hereBits;
          bits -= hereBits;
          if ((hereOp & 64) != 0) {
            msg = 'invalid distance code';
            mode = _bad;
            break;
          }
          offset = here >> 16;

          // get distance extra bits, if any
          extra = hereOp & 15;
          if (extra != 0) {
            // NEEDBITS(extra)
            while (bits < extra) {
              if (have == 0) {
                have = _in();
                next = 0;
                if (have == 0) {
                  ret = bufError;
                  break infLeave;
                }
              }
              have--;
              hold += inBuf[next++] << bits;
              bits += 8;
            }
            offset += hold & ((1 << extra) - 1);
            hold >>= extra;
            bits -= extra;
          }
          if (offset > _wsize - (_wrap != 0 ? 0 : left)) {
            msg = 'invalid distance too far back';
            mode = _bad;
            break;
          }
          mode = _match;
        case _match:
          // copy match from window to output
          do {
            // ROOM()
            if (left == 0) {
              if (put != 0) {
                ret = windowFull;
                break infLeave;
              }
              put = 0;
              left = _wsize;
              _wrap = 1;
            }
            copy = _wsize - offset;
            if (copy < left) {
              from = put + copy;
              copy = left - copy;
            } else {
              from = put - offset;
              copy = left;
            }
            if (copy > length) copy = length;
            length -= copy;
            left -= copy;
            if (put - from >= copy || from > put) {
              // no overlap in the forward direction
              window.setRange(put, put + copy, window, from);
              put += copy;
            } else {
              do {
                window[put++] = window[from++];
              } while (--copy != 0);
            }
          } while (length != 0);
          mode = _len;
        case _lit:
          // ROOM()
          if (left == 0) {
            if (put != 0) {
              ret = windowFull;
              break infLeave;
            }
            put = 0;
            left = _wsize;
            _wrap = 1;
          }
          window[put++] = length;
          left--;
          mode = _len;
        case _done:
          // inflate stream terminated properly: the caller writes the
          // leftover output window[0 .. put)
          ret = streamEnd;
          break infLeave;
        case _bad:
          ret = dataError;
          break infLeave;
        default:
          ret = dataError;
          break infLeave;
      }
    }

    // Save the state (inf_leave: return unused input).
    this.next = next;
    this.have = have;
    this.put = put;
    this.left = left;
    _hold = hold;
    _bits = bits;
    _mode = mode;
    _length = length;
    _offset = offset;
    return ret;
  }

  /// Called by the caller after taking a full window: the next ROOM()
  /// starts over at window[0].
  void windowTaken() {
    put = 0;
  }
}
