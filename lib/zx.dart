/// Pure Dart port of 7-Zip as the public domain LZMA SDK has it (the 7zr
/// program): 7z archives, xz and lzma files, with LZMA, LZMA2, PPMd, the
/// branch filters, Delta, BCJ2 and AES-256.
///
/// Start with [ZxArchive] (every format: 7z, zip, rar, tar and the
/// compressed tars, gzip, bzip2, xz, lzma, lzh, arj, split volumes),
/// [SevenZipArchive] and the xz / lzma helpers: they run in background
/// isolates. The lower level building blocks (the synchronous reader,
/// writer, streams and codecs) are exported too, for callers that run them
/// in their own isolates.
library;

// The isolate based API.
export 'src/api.dart'
    show
        SevenZipArchive,
        SevenZipSource,
        SevenZipOptions,
        SevenZipOverwrite,
        SevenZipProgress,
        SevenZipCancelToken,
        SevenZipListing,
        SevenZipExtractResult,
        SevenZipItemError,
        SevenZipUpdateResult,
        xzCompressFile,
        xzDecompressFile,
        lzmaCompressFile,
        lzmaDecompressFile,
        xzCompress,
        xzDecompress,
        lzmaCompress,
        lzmaDecompress,
        sevenZipCompressBytes,
        sevenZipDecompressBytes;
export 'src/pool.dart' show defaultThreads;

// The generic API: every format through one handle.
export 'src/zx_api.dart'
    show
        ZxArchive,
        ZxListing,
        ZxItem,
        ZxCapabilities,
        ZxOptions,
        ZxSource,
        ZxProgress,
        ZxCancelToken,
        ZxOverwrite,
        ZxOverwriteAnswer,
        ZxOverwriteRequest,
        ZxOverwriteCallback,
        ZxPasswordReason,
        ZxPasswordRequest,
        ZxPasswordCallback,
        ZxExtractResult,
        ZxItemError,
        ZxVersion,
        ZxFileVersion,
        ZxUpdateResult,
        ZxReadme,
        readmeMaxBytes;
// Signed generations of .zx archives (docs/zx-format.md, "Seals") and
// the NOSTR keys that sign them.
export 'src/format/zx/zx_seal.dart'
    show
        ZxGenerationSeal,
        ZxSealState,
        ZxSeal,
        ZxPolicy,
        ZxWriteRule,
        zxCheckSealsOfFile,
        zxSealSummary,
        zxAcceptSignature;
export 'src/crypto/schnorr.dart'
    show
        generateSecretKey,
        publicKeyOf,
        isValidSecretKey,
        isValidPublicKey,
        schnorrSign,
        schnorrVerify,
        SchnorrException;
export 'src/crypto/nip19.dart'
    show npubEncode, nsecEncode, parsePublicKey, parseSecretKey;

// The README of an archive (docs/readme.md).
export 'src/readme/markdown.dart';
export 'src/readme/readme.dart';
export 'src/readme/readme_links.dart';
export 'src/zx_estimate.dart' show ZxCompression, ZxEstimate;
export 'src/cli/zx_zcm_auto.dart' show ZxAutoSpeed;
export 'src/codec/zcm/zcm.dart'
    show ZcmOptions, zcmLevelByName, zcmDefaultMemoryMiB;

// the .zx format (docs/zx-format.md): the synchronous building blocks
export 'src/format/zx/zx_handler.dart'
    show ZxHandler, ZxSeqReader, ZxTimelineVersion, ZxUpdateFileResult;
export 'src/format/zx/zx_writer.dart'
    show
        ZxWriter,
        ZxWriteOptions,
        ZxWriteResult,
        ZxSink,
        ZxStreamSink,
        ZxVolumeSink,
        ZxVolumeDir,
        zxCompact;
export 'src/format/zx/zx_reader.dart'
    show
        ZxArchiveReader,
        ZxOpenParams,
        ZxGenerationSelector,
        ZxMissingVolumeException,
        ZxNeedPasswordException;
export 'src/format/zx/zx_codecs.dart'
    show
        ZxCodecInfo,
        ZxCodecId,
        ZxCoderConfig,
        ZxCoderSpec,
        ZxEncoded,
        registerZxCodec,
        zxCodecById,
        zxCodecByName,
        zxCodecs;
export 'src/format/zx/zx_format.dart'
    show ZxEntry, ZxKind, ZxCheck, ZxIndex, ZxGeneration, ZxHeader;
export 'src/util/tlsh.dart' show Tlsh, tlshDistance;
export 'src/version.dart' show zxVersionString;

// zxdb, the database inside a .zx archive (in a worker isolate).
export 'src/db/zxdb_async.dart'
    show ZxDatabaseAsync, ZxKvStoreAsync, ZxSeriesAsync;
export 'src/db/sql/zx_sql.dart' show ZxSqlResult, zxFormatDatetimeNs, zxIsDatetimeType;
export 'src/db/storage_api.dart' show ZxDbException, ZxDbError;

// Streams and errors.
export 'src/io/streams.dart'
    show
        SevenZipException,
        SevenZipError,
        InStream,
        OutStream,
        SeekableInStream,
        SeekableOutStream,
        MemoryInStream,
        MemoryOutStream,
        FileInStream,
        FileOutStream,
        NullOutStream,
        readAll,
        copyStream;

// The 7z handler: synchronous reader and writer.
export 'src/format/sevenz/sevenz.dart'
    show
        SevenZipReader,
        SevenZipWriter,
        SevenZipEntry,
        SevenZipUpdateItem,
        CompressionOptions,
        ItemResult,
        InvalidArgException,
        availableEncoders,
        fileTimeToDateTime,
        dateTimeToFileTime,
        OperationResult,
        FileAttrib,
        Kpid;

// The other handlers of 7zr.
export 'src/format/xz/xz_handler.dart' show XzArchive;
export 'src/format/lzma_alone.dart' show LzmaAloneArchive, lzmaAloneEncode;
export 'src/format/split.dart' show MultiInStream, MultiOutStream;

// Codecs.
export 'src/codec/codec.dart'
    show
        Compressor,
        FilterCoder,
        PushEncoder,
        CoderContext,
        ProgressCallback,
        PasswordProvider,
        MethodId,
        methodNames;
export 'src/codec/lzma/lzma_coder.dart'
    show
        LzmaCompressor,
        Lzma2Compressor,
        LzmaDecoderStream,
        Lzma2DecoderStream;
export 'src/codec/ppmd/ppmd_coder.dart' show PpmdCompressor, PpmdDecoderStream;
export 'src/codec/copy.dart' show CopyCompressor;
export 'src/codec/filters/filters.dart' show createFilterEncoder;
export 'src/util/crc.dart' show Crc32, Crc64;
export 'src/crypto/sha256.dart' show Sha256;
