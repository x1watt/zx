// Raw deflate compression: port of deflate.c and deflate.h of zlib 1.3.1
// (Jean-loup Gailly and Mark Adler, zlib license, see LICENSE). trees.c is
// in trees.dart (a part of this library, as both files share the
// deflate_state).
//
// The port keeps the stream interface of zlib (next_in, avail_in, next_out,
// avail_out and deflate(strm, flush)), so that the output is byte for byte
// the one of zlib at the same level, strategy, memLevel and window size, fed
// with the same input and output buffer sizes. Only raw deflate is ported
// (windowBits -9..-15 in zlib terms): the zlib and gzip wrappers of
// deflate() are not, the gzip handler writes its own header and trailer.
// deflateSetDictionary, deflateParams, deflateCopy and deflatePrime are not
// ported either.

import 'dart:typed_data';

import 'zutil.dart';

part 'trees.dart';

// deflate.h
const int _lengthCodes = 29; // LENGTH_CODES
const int _literals = 256; // LITERALS
const int _lCodes = _literals + 1 + _lengthCodes; // L_CODES
const int _dCodes = 30; // D_CODES
const int _blCodes = 19; // BL_CODES
const int _heapSize = 2 * _lCodes + 1; // HEAP_SIZE
const int _maxBits = 15; // MAX_BITS
const int _bufSize = 16; // Buf_size

const int _initState = 42; // INIT_STATE
const int _busyState = 113; // BUSY_STATE
const int _finishState = 666; // FINISH_STATE

const int _minLookahead = zMaxMatch + zMinMatch + 1; // MIN_LOOKAHEAD
const int _winInit = zMaxMatch; // WIN_INIT

// deflate.c
const int _nil = 0; // NIL
const int _tooFar = 4096; // TOO_FAR
const int _maxStored = 65535; // MAX_STORED

// block_state
const int _needMore = 0; // need_more
const int _blockDone = 1; // block_done
const int _finishStarted = 2; // finish_started
const int _finishDone = 3; // finish_done

// compress_func
const int _funcStored = 0; // deflate_stored
const int _funcFast = 1; // deflate_fast
const int _funcSlow = 2; // deflate_slow

/// config (deflate.c).
class _Config {
  final int goodLength; // reduce lazy search above this match length
  final int maxLazy; // do not perform lazy search above this match length
  final int niceLength; // quit search above this match length
  final int maxChain;
  final int func;
  const _Config(
      this.goodLength, this.maxLazy, this.niceLength, this.maxChain, this.func);
}

// configuration_table
const List<_Config> _configurationTable = [
  //      good lazy nice chain
  _Config(0, 0, 0, 0, _funcStored), // 0: store only
  _Config(4, 4, 8, 4, _funcFast), // 1: max speed, no lazy matches
  _Config(4, 5, 16, 8, _funcFast), // 2
  _Config(4, 6, 32, 32, _funcFast), // 3
  _Config(4, 4, 16, 16, _funcSlow), // 4: lazy matches
  _Config(8, 16, 32, 32, _funcSlow), // 5
  _Config(8, 16, 128, 128, _funcSlow), // 6
  _Config(8, 32, 128, 256, _funcSlow), // 7
  _Config(32, 128, 258, 1024, _funcSlow), // 8
  _Config(32, 258, 258, 4096, _funcSlow), // 9: max compression
];

// RANK: rank Z_BLOCK between Z_NO_FLUSH and Z_PARTIAL_FLUSH
int _rank(int f) => (f * 2) - (f > 4 ? 9 : 0);

/// The raw deflate compressor: the z_stream fields used by deflate() plus
/// struct internal_state (deflate_state) of deflate.h.
class DeflateState {
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

  /// best guess about the data type: binary or text (ZDataType)
  int dataType = ZDataType.unknown;

  /// last error message, null if no error
  String? msg;

  // ---- deflate_state ----
  int status = _initState; // as the name implies
  late Uint8List pendingBuf; // output still pending
  int pendingBufSize = 0; // size of pending_buf
  int pendingOut = 0; // next pending byte to output to the stream
  int pending = 0; // nb of bytes in the pending buffer
  int lastFlush = -2; // value of flush param for previous deflate call

  int wSize = 0; // LZ77 window size (32K by default)
  int wBits = 0; // log2(w_size)  (8..16)
  int wMask = 0; // w_size - 1

  /// Sliding window. Input bytes are read into the second half of the
  /// window, and move to the first half later to keep a dictionary of at
  /// least wSize bytes.
  late Uint8List window;

  /// Actual size of window: 2*wSize.
  int windowSize = 0;

  /// Link to older string with same hash index.
  late Uint16List prev;

  /// Heads of the hash chains or NIL.
  late Uint16List head;

  int insH = 0; // hash index of string to be inserted
  int hashSize = 0; // number of elements in hash table
  int hashBits = 0; // log2(hash_size)
  int hashMask = 0; // hash_size-1

  /// Number of bits by which ins_h must be shifted at each input step.
  int hashShift = 0;

  /// Window position at the beginning of the current output block. Gets
  /// negative when the window is moved backwards.
  int blockStart = 0;

  int matchLength = 0; // length of best match
  int prevMatch = 0; // previous match
  int matchAvailable = 0; // set if previous match exists
  int strstart = 0; // start of string to insert
  int matchStart = 0; // start of matching string
  int lookahead = 0; // number of valid bytes ahead in window

  /// Length of the best match at previous step.
  int prevLength = 0;

  /// To speed up deflation, hash chains are never searched beyond this
  /// length.
  int maxChainLength = 0;

  /// Attempt to find a better match only when the current match is
  /// strictly smaller than this value (max_insert_length for levels <= 3).
  int maxLazyMatch = 0;

  int level = 0; // compression level (1..9)
  int strategy = 0; // favor or force Huffman coding

  /// Use a faster search when the previous match is longer than this
  int goodMatch = 0;

  /// Stop searching when current match exceeds this
  int niceMatch = 0;

  // ---- used by trees.c ----
  // ct_data is a union of (freq, code) and (dad, len): the port keeps the
  // two unions as two parallel Uint16List, fc and dl.
  final Uint16List dynLtreeFc = Uint16List(_heapSize); // literal and length
  final Uint16List dynLtreeDl = Uint16List(_heapSize);
  final Uint16List dynDtreeFc = Uint16List(2 * _dCodes + 1); // distance
  final Uint16List dynDtreeDl = Uint16List(2 * _dCodes + 1);
  final Uint16List blTreeFc = Uint16List(2 * _blCodes + 1); // bit lengths
  final Uint16List blTreeDl = Uint16List(2 * _blCodes + 1);

  late final _TreeDesc _lDesc; // desc. for literal tree
  late final _TreeDesc _dDesc; // desc. for distance tree
  late final _TreeDesc _blDesc; // desc. for bit length tree

  /// number of codes at each bit length for an optimal tree
  final Uint16List blCount = Uint16List(_maxBits + 1);

  /// heap used to build the Huffman trees
  final Int32List heap = Int32List(2 * _lCodes + 1);
  int heapLen = 0; // number of elements in the heap
  int heapMax = 0; // element of largest frequency

  /// Depth of each subtree used as tie breaker for trees of equal frequency
  final Uint8List depth = Uint8List(2 * _lCodes + 1);

  /// sym_buf: buffer for distances and literals/lengths, at this offset in
  /// pendingBuf (they are overlaid as in zlib).
  int symBuf = 0;

  int litBufsize = 0; // size of match buffer for literals/lengths
  int symNext = 0; // running index in symbol buffer
  int symEnd = 0; // symbol table full when sym_next reaches this

  int optLen = 0; // bit length of current block with optimal trees
  int staticLen = 0; // bit length of current block with static trees
  int matches = 0; // number of string matches in current block
  int insert = 0; // bytes at end of window left to insert

  /// Output buffer. bits are inserted starting at the bottom (least
  /// significant bits).
  int biBuf = 0;

  /// Number of valid bits in bi_buf.
  int biValid = 0;

  /// High water mark offset in window for initialized bytes.
  int highWater = 0;

  /// deflateInit2_ with a negative windowBits (raw deflate) and
  /// method Z_DEFLATED, followed by deflateReset. [level] is 0..9 or -1
  /// (Z_DEFAULT_COMPRESSION, 6), [windowBits] 9..15, [memLevel] 1..9.
  /// Throws [ArgumentError] where zlib returns Z_STREAM_ERROR.
  DeflateState(
      {int level = zDefaultCompression,
      int windowBits = zMaxWbits,
      int memLevel = zDefMemLevel,
      int strategy = ZStrategy.defaultStrategy}) {
    if (level == zDefaultCompression) level = 6;
    if (memLevel < 1 ||
        memLevel > zMaxMemLevel ||
        windowBits < 8 ||
        windowBits > 15 ||
        level < 0 ||
        level > 9 ||
        strategy < 0 ||
        strategy > ZStrategy.fixed ||
        windowBits == 8) {
      throw ArgumentError('deflate: invalid parameters');
    }
    status = _initState; // to pass state test in deflateReset()

    wBits = windowBits;
    wSize = 1 << wBits;
    wMask = wSize - 1;

    hashBits = memLevel + 7;
    hashSize = 1 << hashBits;
    hashMask = hashSize - 1;
    hashShift = (hashBits + zMinMatch - 1) ~/ zMinMatch;

    window = Uint8List(wSize * 2);
    prev = Uint16List(wSize);
    head = Uint16List(hashSize);

    highWater = 0; // nothing written to s.window yet

    litBufsize = 1 << (memLevel + 6); // 16K elements by default

    // We overlay pending_buf and sym_buf (see deflate.c for the analysis).
    pendingBuf = Uint8List(litBufsize * 4);
    pendingBufSize = litBufsize * 4;

    symBuf = litBufsize;
    symEnd = (litBufsize - 1) * 3;

    this.level = level;
    this.strategy = strategy;

    _lDesc = _TreeDesc(dynLtreeFc, dynLtreeDl, _staticLDesc);
    _dDesc = _TreeDesc(dynDtreeFc, dynDtreeDl, _staticDDesc);
    _blDesc = _TreeDesc(blTreeFc, blTreeDl, _staticBlDesc);

    deflateReset();
  }

  // UPDATE_HASH / INSERT_STRING are written inline where they are used.

  // CLEAR_HASH
  void _clearHash() {
    head.fillRange(0, hashSize, _nil);
  }

  // slide_hash
  void _slideHash() {
    final wsize = wSize;
    final h = head;
    for (var n = hashSize - 1; n >= 0; n--) {
      final m = h[n];
      h[n] = m >= wsize ? m - wsize : _nil;
    }
    final p = prev;
    for (var n = wsize - 1; n >= 0; n--) {
      final m = p[n];
      p[n] = m >= wsize ? m - wsize : _nil;
      // If n is not on any hash chain, prev[n] is garbage but its value
      // will never be used.
    }
  }

  // read_buf: reads a new buffer from the current input stream (no
  // adler32 or crc32: raw deflate).
  int _readBuf(Uint8List buf, int bufPos, int size) {
    var len = availIn;
    if (len > size) len = size;
    if (len == 0) return 0;

    availIn -= len;

    buf.setRange(bufPos, bufPos + len, nextIn, nextInPos);
    nextInPos += len;
    totalIn += len;

    return len;
  }

  // fill_window: fills the window when the lookahead becomes
  // insufficient. Updates strstart and lookahead.
  void _fillWindow() {
    int n;
    int more; // Amount of free space at the end of the window.
    final wsize = wSize;

    do {
      more = windowSize - lookahead - strstart;

      // If the window is almost full and there is insufficient lookahead,
      // move the upper half to the lower one to make room in the upper half.
      if (strstart >= wsize + (wSize - _minLookahead)) {
        window.setRange(0, wsize - more, window, wsize);
        matchStart -= wsize;
        strstart -= wsize; // we now have strstart >= MAX_DIST
        blockStart -= wsize;
        if (insert > strstart) insert = strstart;
        _slideHash();
        more += wsize;
      }
      if (availIn == 0) break;

      n = _readBuf(window, strstart + lookahead, more);
      lookahead += n;

      // Initialize the hash value now that we have some input:
      if (lookahead + insert >= zMinMatch) {
        var str = strstart - insert;
        final win = window;
        var h = win[str];
        h = ((h << hashShift) ^ win[str + 1]) & hashMask;
        while (insert != 0) {
          h = ((h << hashShift) ^ win[str + zMinMatch - 1]) & hashMask;
          prev[str & wMask] = head[h];
          head[h] = str;
          str++;
          insert--;
          if (lookahead + insert < zMinMatch) break;
        }
        insH = h;
      }
      // If the whole input has less than MIN_MATCH bytes, ins_h is garbage,
      // but this is not important since only literal bytes will be emitted.
    } while (lookahead < _minLookahead && availIn != 0);

    // If the WIN_INIT bytes after the end of the current data have never
    // been written, then zero those bytes (as zlib does, so that the longest
    // match routines see the same bytes).
    if (highWater < windowSize) {
      final curr = strstart + lookahead;
      int init;

      if (highWater < curr) {
        // Previous high water mark below current data: zero WIN_INIT
        // bytes or up to end of window, whichever is less.
        init = windowSize - curr;
        if (init > _winInit) init = _winInit;
        window.fillRange(curr, curr + init, 0);
        highWater = curr + init;
      } else if (highWater < curr + _winInit) {
        // High water mark at or above current data, but below current data
        // plus WIN_INIT: zero out to current data plus WIN_INIT, or up to
        // end of window, whichever is less.
        init = curr + _winInit - highWater;
        if (init > windowSize - highWater) init = windowSize - highWater;
        window.fillRange(highWater, highWater + init, 0);
        highWater += init;
      }
    }
  }

  // deflateResetKeep
  void _deflateResetKeep() {
    totalIn = totalOut = 0;
    msg = null;
    dataType = ZDataType.unknown;

    pending = 0;
    pendingOut = 0;

    status = _busyState; // raw deflate: INIT_STATE goes to BUSY_STATE
    lastFlush = -2;

    _trInit();
  }

  // lm_init: initializes the "longest match" routines for a new stream.
  void _lmInit() {
    windowSize = 2 * wSize;

    _clearHash();

    // Set the default configuration parameters:
    final c = _configurationTable[level];
    maxLazyMatch = c.maxLazy;
    goodMatch = c.goodLength;
    niceMatch = c.niceLength;
    maxChainLength = c.maxChain;

    strstart = 0;
    blockStart = 0;
    lookahead = 0;
    insert = 0;
    matchLength = prevLength = zMinMatch - 1;
    matchAvailable = 0;
    insH = 0;
  }

  /// deflateReset
  void deflateReset() {
    _deflateResetKeep();
    _lmInit();
  }

  /// deflateTune
  void deflateTune(int goodLength, int maxLazy, int niceLength, int maxChain) {
    goodMatch = goodLength;
    maxLazyMatch = maxLazy;
    niceMatch = niceLength;
    maxChainLength = maxChain;
  }

  /// deflateBound for raw deflate (wraplen 0).
  int deflateBound(int sourceLen) {
    // upper bound for fixed blocks with 9-bit literals and length 255
    final fixedlen = sourceLen +
        (sourceLen >> 3) +
        (sourceLen >> 8) +
        (sourceLen >> 9) +
        4;

    // upper bound for stored blocks with length 127 (memLevel == 1)
    final storelen = sourceLen +
        (sourceLen >> 5) +
        (sourceLen >> 7) +
        (sourceLen >> 11) +
        7;

    // if not default parameters, return one of the conservative bounds
    if (wBits != 15 || hashBits != 8 + 7) {
      return (wBits <= hashBits && level != 0) ? fixedlen : storelen;
    }

    // default settings: return tight bound for that case
    return sourceLen +
        (sourceLen >> 12) +
        (sourceLen >> 14) +
        (sourceLen >> 25) +
        13 -
        6;
  }

  // flush_pending: flushes as much pending output as possible.
  void _flushPending() {
    _trFlushBits();
    var len = pending;
    if (len > availOut) len = availOut;
    if (len == 0) return;

    nextOut.setRange(nextOutPos, nextOutPos + len, pendingBuf, pendingOut);
    nextOutPos += len;
    pendingOut += len;
    totalOut += len;
    availOut -= len;
    pending -= len;
    if (pending == 0) pendingOut = 0;
  }

  /// deflate: compresses as much as possible from nextIn to nextOut.
  /// Returns a [ZResult] value.
  int deflate(int flush) {
    if (flush > ZFlush.block || flush < 0) return ZResult.streamError;

    if (status == _finishState && flush != ZFlush.finish) {
      msg = 'stream error';
      return ZResult.streamError;
    }
    if (availOut == 0) {
      msg = 'buffer error';
      return ZResult.bufError;
    }

    final oldFlush = lastFlush;
    lastFlush = flush;

    // Flush as much pending output as possible
    if (pending != 0) {
      _flushPending();
      if (availOut == 0) {
        // Since avail_out is 0, deflate will be called again with more
        // output space, but possibly with both pending and avail_in equal
        // to zero. There won't be anything to do, but this is not an error
        // situation so make sure we return OK instead of BUF_ERROR at next
        // call of deflate:
        lastFlush = -1;
        return ZResult.ok;
      }

      // Make sure there is something to do and avoid duplicate consecutive
      // flushes. For repeated and useless calls with Z_FINISH, we keep
      // returning Z_STREAM_END instead of Z_BUF_ERROR.
    } else if (availIn == 0 &&
        _rank(flush) <= _rank(oldFlush) &&
        flush != ZFlush.finish) {
      msg = 'buffer error';
      return ZResult.bufError;
    }

    // User must not provide more input after the first FINISH:
    if (status == _finishState && availIn != 0) {
      msg = 'buffer error';
      return ZResult.bufError;
    }

    // Raw deflate: no header (status is BUSY_STATE from the reset).

    // Start a new block or continue the current one.
    if (availIn != 0 ||
        lookahead != 0 ||
        (flush != ZFlush.noFlush && status != _finishState)) {
      int bstate;
      if (level == 0) {
        bstate = _deflateStored(flush);
      } else if (strategy == ZStrategy.huffmanOnly) {
        bstate = _deflateHuff(flush);
      } else if (strategy == ZStrategy.rle) {
        bstate = _deflateRle(flush);
      } else if (_configurationTable[level].func == _funcFast) {
        bstate = _deflateFast(flush);
      } else {
        bstate = _deflateSlow(flush);
      }

      if (bstate == _finishStarted || bstate == _finishDone) {
        status = _finishState;
      }
      if (bstate == _needMore || bstate == _finishStarted) {
        if (availOut == 0) {
          lastFlush = -1; // avoid BUF_ERROR next call, see above
        }
        return ZResult.ok;
        // If flush != Z_NO_FLUSH && avail_out == 0, the next call of
        // deflate should use the same flush parameter to make sure that
        // the flush is complete. So we don't have to output an empty block
        // here, this will be done at next call. This also ensures that for
        // a very small output buffer, we emit at most one empty block.
      }
      if (bstate == _blockDone) {
        if (flush == ZFlush.partialFlush) {
          _trAlign();
        } else if (flush != ZFlush.block) {
          // FULL_FLUSH or SYNC_FLUSH
          _trStoredBlock(-1, 0, 0);
          // For a full flush, this empty block will be recognized as a
          // special marker by inflate_sync().
          if (flush == ZFlush.fullFlush) {
            _clearHash(); // forget history
            if (lookahead == 0) {
              strstart = 0;
              blockStart = 0;
              insert = 0;
            }
          }
        }
        _flushPending();
        if (availOut == 0) {
          lastFlush = -1; // avoid BUF_ERROR at next call, see above
          return ZResult.ok;
        }
      }
    }

    if (flush != ZFlush.finish) return ZResult.ok;
    return ZResult.streamEnd; // raw deflate: no trailer
  }

  /// deflateEnd: returns Z_DATA_ERROR when the stream was freed
  /// prematurely (some input or output was discarded).
  int deflateEnd() {
    final s = status;
    status = _finishState;
    return s == _busyState ? ZResult.dataError : ZResult.ok;
  }

  // longest_match: sets match_start to the longest match starting at the
  // given string and returns its length. Matches shorter or equal to
  // prev_length are discarded, in which case the result is equal to
  // prev_length and match_start is garbage.
  int _longestMatch(int curMatch) {
    var chainLength = maxChainLength; // max hash chain length
    final win = window;
    final scanStart = strstart; // current string
    var bestLen = prevLength; // best match length so far
    var nice = niceMatch; // stop if match long enough
    final maxDist = wSize - _minLookahead;
    final limit = strstart > maxDist ? strstart - maxDist : _nil;
    // Stop when cur_match becomes <= limit. To simplify the code, we
    // prevent matches with the string of window index 0.
    final prv = prev;
    final wmask = wMask;

    final strend = scanStart + zMaxMatch;
    var scanEnd1 = win[scanStart + bestLen - 1];
    var scanEnd = win[scanStart + bestLen];
    final scan0 = win[scanStart];
    final scan1 = win[scanStart + 1];

    // Do not waste too much time if we already have a good match:
    if (prevLength >= goodMatch) chainLength >>= 2;

    // Do not look for matches beyond the end of the input. This is
    // necessary to make deflate deterministic.
    if (nice > lookahead) nice = lookahead;

    do {
      var match = curMatch;

      // Skip to next match if the match length cannot increase or if the
      // match length is less than 2.
      if (win[match + bestLen] != scanEnd ||
          win[match + bestLen - 1] != scanEnd1 ||
          win[match] != scan0 ||
          win[++match] != scan1) {
        continue;
      }

      // It is not necessary to compare scan[2] and match[2] since they are
      // always equal when the other bytes match, given that the hash keys
      // are equal and that HASH_BITS >= 8.
      var scan = scanStart + 2;
      match++;

      // We check for insufficient lookahead only every 8th comparison; the
      // 256th check will be made at strstart + 258.
      while (win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          win[++scan] == win[++match] &&
          scan < strend) {}

      final len = zMaxMatch - (strend - scan);

      if (len > bestLen) {
        matchStart = curMatch;
        bestLen = len;
        if (len >= nice) break;
        scanEnd1 = win[scanStart + bestLen - 1];
        scanEnd = win[scanStart + bestLen];
      }
    } while ((curMatch = prv[curMatch & wmask]) > limit && --chainLength != 0);

    if (bestLen <= lookahead) return bestLen;
    return lookahead;
  }

  // FLUSH_BLOCK_ONLY: flushes the current block, with given end-of-file
  // flag.
  void _flushBlockOnly(int last) {
    _trFlushBlock(blockStart >= 0 ? blockStart : -1, strstart - blockStart,
        last);
    blockStart = strstart;
    _flushPending();
  }

  // _tr_tally_lit (the inline macro of deflate.h): returns true when the
  // block must be flushed.
  bool _tallyLit(int c) {
    final buf = pendingBuf;
    var i = symBuf + symNext;
    buf[i++] = 0;
    buf[i++] = 0;
    buf[i] = c;
    symNext += 3;
    dynLtreeFc[c]++;
    return symNext == symEnd;
  }

  // _tr_tally_dist (the inline macro of deflate.h): returns true when the
  // block must be flushed.
  bool _tallyDist(int distance, int length) {
    final buf = pendingBuf;
    var i = symBuf + symNext;
    buf[i++] = distance & 0xff;
    buf[i++] = (distance >> 8) & 0xff;
    buf[i] = length;
    symNext += 3;
    final dist = distance - 1;
    dynLtreeFc[_lengthCode[length] + _literals + 1]++;
    dynDtreeFc[dist < 256 ? _distCode[dist] : _distCode[256 + (dist >> 7)]]++;
    return symNext == symEnd;
  }

  // deflate_stored: copies without compression as much as possible from
  // the input stream, returns the current block state.
  int _deflateStored(int flush) {
    // Smallest worthy block size when not flushing or finishing. By default
    // this is 32K. For large input and output buffers, the stored block
    // size will be larger.
    var minBlock = pendingBufSize - 5 < wSize ? pendingBufSize - 5 : wSize;

    // Copy as many min_block or larger stored blocks directly to next_out
    // as possible. If flushing, copy the remaining available input to
    // next_out as stored blocks, if there is enough space.
    int len, left, have;
    var last = 0;
    var used = availIn;
    do {
      // Set len to the maximum size block that we can copy directly with
      // the available input data and output space. Set left to how much of
      // that would be copied from what's left in the window.
      len = _maxStored; // maximum deflate stored block length
      have = (biValid + 42) >> 3; // number of header bytes
      if (availOut < have) break; // need room for header
      // maximum stored block length that will fit in avail_out:
      have = availOut - have;
      left = strstart - blockStart; // bytes left in window
      if (len > left + availIn) len = left + availIn; // limit len to input
      if (len > have) len = have; // limit len to the output

      // If the stored block would be less than min_block in length, or if
      // unable to copy all of the available input when flushing, then try
      // copying to the window and the pending buffer instead. Also don't
      // write an empty block when flushing, deflate() does that.
      if (len < minBlock &&
          ((len == 0 && flush != ZFlush.finish) ||
              flush == ZFlush.noFlush ||
              len != left + availIn)) {
        break;
      }

      // Make a dummy stored block in pending to get the header bytes,
      // including any pending bits.
      last = flush == ZFlush.finish && len == left + availIn ? 1 : 0;
      _trStoredBlock(-1, 0, last);

      // Replace the lengths in the dummy stored block with len.
      pendingBuf[pending - 4] = len & 0xff;
      pendingBuf[pending - 3] = (len >> 8) & 0xff;
      pendingBuf[pending - 2] = (~len) & 0xff;
      pendingBuf[pending - 1] = (~len >> 8) & 0xff;

      // Write the stored block header bytes.
      _flushPending();

      // Copy uncompressed bytes from the window to next_out.
      if (left != 0) {
        if (left > len) left = len;
        nextOut.setRange(nextOutPos, nextOutPos + left, window, blockStart);
        nextOutPos += left;
        availOut -= left;
        totalOut += left;
        blockStart += left;
        len -= left;
      }

      // Copy uncompressed bytes directly from next_in to next_out.
      if (len != 0) {
        _readBuf(nextOut, nextOutPos, len);
        nextOutPos += len;
        availOut -= len;
        totalOut += len;
      }
    } while (last == 0);

    // Update the sliding window with the last s.w_size bytes of the copied
    // data, or append all of the copied data to the existing window if less
    // than s.w_size bytes were copied. Also update the number of bytes to
    // insert in the hash tables.
    used -= availIn; // number of input bytes directly copied
    if (used != 0) {
      // If any input was used, then no unused input remains in the window,
      // therefore s.block_start == s.strstart.
      if (used >= wSize) {
        // supplant the previous history
        matches = 2; // clear hash
        window.setRange(0, wSize, nextIn, nextInPos - wSize);
        strstart = wSize;
        insert = strstart;
      } else {
        if (windowSize - strstart <= used) {
          // Slide the window down.
          strstart -= wSize;
          window.setRange(0, strstart, window, wSize);
          if (matches < 2) matches++; // add a pending slide_hash()
          if (insert > strstart) insert = strstart;
        }
        window.setRange(strstart, strstart + used, nextIn, nextInPos - used);
        strstart += used;
        insert += used < wSize - insert ? used : wSize - insert;
      }
      blockStart = strstart;
    }
    if (highWater < strstart) highWater = strstart;

    // If the last block was written to next_out, then done.
    if (last != 0) return _finishDone;

    // If flushing and all input has been consumed, then done.
    if (flush != ZFlush.noFlush &&
        flush != ZFlush.finish &&
        availIn == 0 &&
        strstart == blockStart) {
      return _blockDone;
    }

    // Fill the window with any remaining input.
    have = windowSize - strstart;
    if (availIn > have && blockStart >= wSize) {
      // Slide the window down.
      blockStart -= wSize;
      strstart -= wSize;
      window.setRange(0, strstart, window, wSize);
      if (matches < 2) matches++; // add a pending slide_hash()
      have += wSize; // more space now
      if (insert > strstart) insert = strstart;
    }
    if (have > availIn) have = availIn;
    if (have != 0) {
      _readBuf(window, strstart, have);
      strstart += have;
      insert += have < wSize - insert ? have : wSize - insert;
    }
    if (highWater < strstart) highWater = strstart;

    // There was not enough avail_out to write a complete worthy or flushed
    // stored block to next_out. Write a stored block to pending instead, if
    // we have enough input for a worthy block, or if flushing and there is
    // enough room for the remaining input as a stored block in the pending
    // buffer.
    have = (biValid + 42) >> 3; // number of header bytes
    // maximum stored block length that will fit in pending:
    have = pendingBufSize - have < _maxStored ? pendingBufSize - have : _maxStored;
    minBlock = have < wSize ? have : wSize;
    left = strstart - blockStart;
    if (left >= minBlock ||
        ((left != 0 || flush == ZFlush.finish) &&
            flush != ZFlush.noFlush &&
            availIn == 0 &&
            left <= have)) {
      len = left < have ? left : have;
      last = flush == ZFlush.finish && availIn == 0 && len == left ? 1 : 0;
      _trStoredBlock(blockStart, len, last);
      blockStart += len;
      _flushPending();
    }

    // We've done all we can with the available input and output.
    return last != 0 ? _finishStarted : _needMore;
  }

  // deflate_fast: compresses as much as possible from the input stream,
  // returns the current block state. This function does not perform lazy
  // evaluation of matches and inserts new strings in the dictionary only
  // for unmatched strings or for short matches. It is used only for the
  // fast compression options.
  int _deflateFast(int flush) {
    int hashHead; // head of the hash chain
    bool bflush; // set if current block must be flushed
    final win = window;
    final prv = prev;
    final hd = head;
    final wmask = wMask;
    final hshift = hashShift;
    final hmask = hashMask;
    final maxDist = wSize - _minLookahead;

    for (;;) {
      // Make sure that we always have enough lookahead, except at the end
      // of the input file. We need MAX_MATCH bytes for the next match, plus
      // MIN_MATCH bytes to insert the string following the next match.
      if (lookahead < _minLookahead) {
        _fillWindow();
        if (lookahead < _minLookahead && flush == ZFlush.noFlush) {
          return _needMore;
        }
        if (lookahead == 0) break; // flush the current block
      }

      // Insert the string window[strstart .. strstart + 2] in the
      // dictionary, and set hash_head to the head of the hash chain:
      hashHead = _nil;
      if (lookahead >= zMinMatch) {
        final str = strstart;
        final h = ((insH << hshift) ^ win[str + zMinMatch - 1]) & hmask;
        insH = h;
        hashHead = prv[str & wmask] = hd[h];
        hd[h] = str;
      }

      // Find the longest match, discarding those <= prev_length. At this
      // point we have always match_length < MIN_MATCH
      if (hashHead != _nil && strstart - hashHead <= maxDist) {
        // To simplify the code, we prevent matches with the string of
        // window index 0 (in particular we have to avoid a match of the
        // string with itself at the start of the input file).
        matchLength = _longestMatch(hashHead);
        // longest_match() sets match_start
      }
      if (matchLength >= zMinMatch) {
        bflush =
            _tallyDist(strstart - matchStart, matchLength - zMinMatch);

        lookahead -= matchLength;

        // Insert new strings in the hash table only if the match length is
        // not too large. This saves time but degrades compression.
        if (matchLength <= maxLazyMatch && lookahead >= zMinMatch) {
          matchLength--; // string at strstart already in table
          var h = insH;
          var str = strstart;
          do {
            str++;
            h = ((h << hshift) ^ win[str + zMinMatch - 1]) & hmask;
            prv[str & wmask] = hd[h];
            hd[h] = str;
            // strstart never exceeds WSIZE-MAX_MATCH, so there are always
            // MIN_MATCH bytes ahead.
          } while (--matchLength != 0);
          insH = h;
          strstart = str + 1;
        } else {
          strstart += matchLength;
          matchLength = 0;
          var h = win[strstart];
          h = ((h << hshift) ^ win[strstart + 1]) & hmask;
          insH = h;
          // If lookahead < MIN_MATCH, ins_h is garbage, but it does not
          // matter since it will be recomputed at next deflate call.
        }
      } else {
        // No match, output a literal byte
        bflush = _tallyLit(win[strstart]);
        lookahead--;
        strstart++;
      }
      if (bflush) {
        // FLUSH_BLOCK(s, 0)
        _flushBlockOnly(0);
        if (availOut == 0) return _needMore;
      }
    }
    insert = strstart < zMinMatch - 1 ? strstart : zMinMatch - 1;
    if (flush == ZFlush.finish) {
      _flushBlockOnly(1);
      if (availOut == 0) return _finishStarted;
      return _finishDone;
    }
    if (symNext != 0) {
      _flushBlockOnly(0);
      if (availOut == 0) return _needMore;
    }
    return _blockDone;
  }

  // deflate_slow: same as above, but achieves better compression. We use a
  // lazy evaluation for matches: a match is finally adopted only if there
  // is no better match at the next window position.
  int _deflateSlow(int flush) {
    int hashHead; // head of hash chain
    bool bflush; // set if current block must be flushed
    final win = window;
    final prv = prev;
    final hd = head;
    final wmask = wMask;
    final hshift = hashShift;
    final hmask = hashMask;
    final maxDist = wSize - _minLookahead;

    // Process the input block.
    for (;;) {
      // Make sure that we always have enough lookahead, except at the end
      // of the input file. We need MAX_MATCH bytes for the next match, plus
      // MIN_MATCH bytes to insert the string following the next match.
      if (lookahead < _minLookahead) {
        _fillWindow();
        if (lookahead < _minLookahead && flush == ZFlush.noFlush) {
          return _needMore;
        }
        if (lookahead == 0) break; // flush the current block
      }

      // Insert the string window[strstart .. strstart + 2] in the
      // dictionary, and set hash_head to the head of the hash chain:
      hashHead = _nil;
      if (lookahead >= zMinMatch) {
        final str = strstart;
        final h = ((insH << hshift) ^ win[str + zMinMatch - 1]) & hmask;
        insH = h;
        hashHead = prv[str & wmask] = hd[h];
        hd[h] = str;
      }

      // Find the longest match, discarding those <= prev_length.
      prevLength = matchLength;
      prevMatch = matchStart;
      matchLength = zMinMatch - 1;

      if (hashHead != _nil &&
          prevLength < maxLazyMatch &&
          strstart - hashHead <= maxDist) {
        // To simplify the code, we prevent matches with the string of
        // window index 0 (in particular we have to avoid a match of the
        // string with itself at the start of the input file).
        matchLength = _longestMatch(hashHead);
        // longest_match() sets match_start

        if (matchLength <= 5 &&
            (strategy == ZStrategy.filtered ||
                (matchLength == zMinMatch &&
                    strstart - matchStart > _tooFar))) {
          // If prev_match is also MIN_MATCH, match_start is garbage but we
          // will ignore the current match anyway.
          matchLength = zMinMatch - 1;
        }
      }
      // If there was a match at the previous step and the current match is
      // not better, output the previous match:
      if (prevLength >= zMinMatch && matchLength <= prevLength) {
        final maxInsert = strstart + lookahead - zMinMatch;
        // Do not insert strings in hash table beyond this.

        bflush =
            _tallyDist(strstart - 1 - prevMatch, prevLength - zMinMatch);

        // Insert in hash table all strings up to the end of the match.
        // strstart - 1 and strstart are already inserted. If there is not
        // enough lookahead, the last two strings are not inserted in the
        // hash table.
        lookahead -= prevLength - 1;
        prevLength -= 2;
        var h = insH;
        var str = strstart;
        do {
          if (++str <= maxInsert) {
            h = ((h << hshift) ^ win[str + zMinMatch - 1]) & hmask;
            prv[str & wmask] = hd[h];
            hd[h] = str;
          }
        } while (--prevLength != 0);
        insH = h;
        matchAvailable = 0;
        matchLength = zMinMatch - 1;
        strstart = str + 1;

        if (bflush) {
          // FLUSH_BLOCK(s, 0)
          _flushBlockOnly(0);
          if (availOut == 0) return _needMore;
        }
      } else if (matchAvailable != 0) {
        // If there was no match at the previous position, output a single
        // literal. If there was a match but the current match is longer,
        // truncate the previous match to a single literal.
        bflush = _tallyLit(win[strstart - 1]);
        if (bflush) _flushBlockOnly(0);
        strstart++;
        lookahead--;
        if (availOut == 0) return _needMore;
      } else {
        // There is no previous match to compare with, wait for the next
        // step to decide.
        matchAvailable = 1;
        strstart++;
        lookahead--;
      }
    }
    if (matchAvailable != 0) {
      _tallyLit(win[strstart - 1]);
      matchAvailable = 0;
    }
    insert = strstart < zMinMatch - 1 ? strstart : zMinMatch - 1;
    if (flush == ZFlush.finish) {
      _flushBlockOnly(1);
      if (availOut == 0) return _finishStarted;
      return _finishDone;
    }
    if (symNext != 0) {
      _flushBlockOnly(0);
      if (availOut == 0) return _needMore;
    }
    return _blockDone;
  }

  // deflate_rle: for Z_RLE, simply look for runs of bytes, generate
  // matches only of distance one. Do not maintain a hash table.
  int _deflateRle(int flush) {
    bool bflush; // set if current block must be flushed
    final win = window;

    for (;;) {
      // Make sure that we always have enough lookahead, except at the end
      // of the input file. We need MAX_MATCH bytes for the longest run, plus
      // one for the unrolled loop.
      if (lookahead <= zMaxMatch) {
        _fillWindow();
        if (lookahead <= zMaxMatch && flush == ZFlush.noFlush) {
          return _needMore;
        }
        if (lookahead == 0) break; // flush the current block
      }

      // See how many times the previous byte repeats
      matchLength = 0;
      if (lookahead >= zMinMatch && strstart > 0) {
        var scan = strstart - 1;
        final prevByte = win[scan];
        if (prevByte == win[++scan] &&
            prevByte == win[++scan] &&
            prevByte == win[++scan]) {
          final strend = strstart + zMaxMatch;
          while (prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              prevByte == win[++scan] &&
              scan < strend) {}
          matchLength = zMaxMatch - (strend - scan);
          if (matchLength > lookahead) matchLength = lookahead;
        }
      }

      // Emit match if have run of MIN_MATCH or longer, else emit literal
      if (matchLength >= zMinMatch) {
        bflush = _tallyDist(1, matchLength - zMinMatch);

        lookahead -= matchLength;
        strstart += matchLength;
        matchLength = 0;
      } else {
        // No match, output a literal byte
        bflush = _tallyLit(win[strstart]);
        lookahead--;
        strstart++;
      }
      if (bflush) {
        _flushBlockOnly(0);
        if (availOut == 0) return _needMore;
      }
    }
    insert = 0;
    if (flush == ZFlush.finish) {
      _flushBlockOnly(1);
      if (availOut == 0) return _finishStarted;
      return _finishDone;
    }
    if (symNext != 0) {
      _flushBlockOnly(0);
      if (availOut == 0) return _needMore;
    }
    return _blockDone;
  }

  // deflate_huff: for Z_HUFFMAN_ONLY, do not look for matches. Do not
  // maintain a hash table.
  int _deflateHuff(int flush) {
    bool bflush; // set if current block must be flushed

    for (;;) {
      // Make sure that we have a literal to write.
      if (lookahead == 0) {
        _fillWindow();
        if (lookahead == 0) {
          if (flush == ZFlush.noFlush) return _needMore;
          break; // flush the current block
        }
      }

      // Output a literal byte
      matchLength = 0;
      bflush = _tallyLit(window[strstart]);
      lookahead--;
      strstart++;
      if (bflush) {
        _flushBlockOnly(0);
        if (availOut == 0) return _needMore;
      }
    }
    insert = 0;
    if (flush == ZFlush.finish) {
      _flushBlockOnly(1);
      if (availOut == 0) return _finishStarted;
      return _finishDone;
    }
    if (symNext != 0) {
      _flushBlockOnly(0);
      if (availOut == 0) return _needMore;
    }
    return _blockDone;
  }
}
