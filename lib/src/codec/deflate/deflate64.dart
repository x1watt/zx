// The Deflate64 variants of the functions of deflate.c that use the hash
// chains (a part of deflate.dart). They are the zlib functions of
// deflate.dart with 32-bit positions (prev32, head32): the 64 KiB window
// of Deflate64 has positions up to 128 KiB, which do not fit the 16-bit
// Pos of zlib. Keeping two copies leaves the 16-bit tables, and so the
// speed, of plain Deflate unchanged. longest_match also cuts matches to
// 257 bytes (see DeflateState).

part of 'deflate.dart';

extension _Deflate64 on DeflateState {
  // slide_hash (Deflate64)
  void _slideHash64() {
    final wsize = wSize;
    final h = head32;
    for (var n = hashSize - 1; n >= 0; n--) {
      final m = h[n];
      h[n] = m >= wsize ? m - wsize : _nil;
    }
    final p = prev32;
    for (var n = wsize - 1; n >= 0; n--) {
      final m = p[n];
      p[n] = m >= wsize ? m - wsize : _nil;
      // If n is not on any hash chain, prev[n] is garbage but its value
      // will never be used.
    }
  }

  // longest_match (Deflate64): sets match_start to the longest match starting at the
  // given string and returns its length. Matches shorter or equal to
  // prev_length are discarded, in which case the result is equal to
  // prev_length and match_start is garbage.
  int _longestMatch64(int curMatch) {
    var chainLength = maxChainLength; // max hash chain length
    final win = window;
    final scanStart = strstart; // current string
    var bestLen = prevLength; // best match length so far
    var nice = niceMatch; // stop if match long enough
    final maxDist = wSize - _minLookahead;
    final limit = strstart > maxDist ? strstart - maxDist : _nil;
    // Stop when cur_match becomes <= limit. To simplify the code, we
    // prevent matches with the string of window index 0.
    final prv = prev32;
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

    // at most 257 bytes, as 7-Zip's Deflate64 encoder (kMatchMaxLen64);
    // 258 would need the 16 extra bits of code 285
    if (bestLen > _maxMatch64) bestLen = _maxMatch64;
    if (bestLen <= lookahead) return bestLen;
    return lookahead;
  }

  // deflate_fast (Deflate64): compresses as much as possible from the input stream,
  // returns the current block state. This function does not perform lazy
  // evaluation of matches and inserts new strings in the dictionary only
  // for unmatched strings or for short matches. It is used only for the
  // fast compression options.
  int _deflateFast64(int flush) {
    int hashHead; // head of the hash chain
    bool bflush; // set if current block must be flushed
    final win = window;
    final prv = prev32;
    final hd = head32;
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
        matchLength = _longestMatch64(hashHead);
        // longest_match() sets match_start
      }
      if (matchLength >= zMinMatch) {
        bflush = _tallyDist(strstart - matchStart, matchLength - zMinMatch);

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

  // deflate_slow (Deflate64): same as above, but achieves better compression. We use a
  // lazy evaluation for matches: a match is finally adopted only if there
  // is no better match at the next window position.
  int _deflateSlow64(int flush) {
    int hashHead; // head of hash chain
    bool bflush; // set if current block must be flushed
    final win = window;
    final prv = prev32;
    final hd = head32;
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
        matchLength = _longestMatch64(hashHead);
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

        bflush = _tallyDist(strstart - 1 - prevMatch, prevLength - zMinMatch);

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
}
