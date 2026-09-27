// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

/// Pure Dart port of the ZPAQ journaling archiver (libzpaq / zpaqfranz).
///
/// Incremental, deduplicated, versioned backups whose archives can be read
/// and updated by zpaq 7.15 and zpaqfranz, and vice versa.
library;

export 'api.dart' show ZpaqArchive, ZpaqListing;
export 'archive/add.dart'
    show
        ZpaqSource,
        ZpaqAddOptions,
        ZpaqAddProgress,
        ZpaqAddResult,
        ZpaqFileHash;
export 'archive/extract.dart' show ZpaqExtractProgress, ZpaqExtractResult;
export 'archive/franz.dart' show FranzInfo;
export 'archive/index.dart' show ZpaqEntry, ZpaqVersion;
export 'archive/zdate.dart' show formatDecimalDate;
export 'core/io.dart' show ZpaqException;
export 'codec.dart';
