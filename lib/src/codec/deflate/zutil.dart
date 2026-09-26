// The zlib constants shared by the deflate and inflate ports: zlib.h and
// zutil.h of zlib 1.3.1 (zlib license, see LICENSE).

/// Flush values of deflate() and inflate() (zlib.h).
abstract final class ZFlush {
  static const noFlush = 0; // Z_NO_FLUSH
  static const partialFlush = 1; // Z_PARTIAL_FLUSH
  static const syncFlush = 2; // Z_SYNC_FLUSH
  static const fullFlush = 3; // Z_FULL_FLUSH
  static const finish = 4; // Z_FINISH
  static const block = 5; // Z_BLOCK
  static const trees = 6; // Z_TREES
}

/// Return codes of deflate() and inflate() (zlib.h).
abstract final class ZResult {
  static const ok = 0; // Z_OK
  static const streamEnd = 1; // Z_STREAM_END
  static const needDict = 2; // Z_NEED_DICT
  static const errno = -1; // Z_ERRNO
  static const streamError = -2; // Z_STREAM_ERROR
  static const dataError = -3; // Z_DATA_ERROR
  static const memError = -4; // Z_MEM_ERROR
  static const bufError = -5; // Z_BUF_ERROR
}

/// Compression strategies (zlib.h).
abstract final class ZStrategy {
  static const defaultStrategy = 0; // Z_DEFAULT_STRATEGY
  static const filtered = 1; // Z_FILTERED
  static const huffmanOnly = 2; // Z_HUFFMAN_ONLY
  static const rle = 3; // Z_RLE
  static const fixed = 4; // Z_FIXED
}

/// strm.data_type values (zlib.h).
abstract final class ZDataType {
  static const binary = 0; // Z_BINARY
  static const text = 1; // Z_TEXT
  static const unknown = 2; // Z_UNKNOWN
}

// zutil.h
const int zMinMatch = 3; // MIN_MATCH
const int zMaxMatch = 258; // MAX_MATCH
const int zMaxWbits = 15; // MAX_WBITS
const int zDefMemLevel = 8; // DEF_MEM_LEVEL
const int zMaxMemLevel = 9; // MAX_MEM_LEVEL
const int zStoredBlock = 0; // STORED_BLOCK
const int zStaticTrees = 1; // STATIC_TREES
const int zDynTrees = 2; // DYN_TREES
const int zDefaultCompression = -1; // Z_DEFAULT_COMPRESSION
