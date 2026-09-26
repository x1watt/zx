# Architecture

How the port is organised, what it keeps from the LZMA SDK, and the rules a
change must respect to stay compatible with 7-Zip and within the license.
Read it together with `docs/performance.md`.

## 1. Principles

1. **Only the public domain SDK.** The reference is the LZMA SDK 26.01,
   unpacked in `ref/lzma-sdk-26.01` (not committed). It contains the
   complete `7zr` program (`CPP/7zip/Bundles/Alone7z`): the 7z handler, the
   xz, lzma and split handlers, all their codecs and the console UI with
   7-Zip's switch parser. Do not read or copy code from the full 7-Zip
   source (GNU LGPL): this package is BSD 3-clause, which is only possible
   because every line comes from the public domain SDK.
2. **A port, not a reimplementation.** Every file follows its C/C++ source
   function by function, so that the two can be read side by side, and so
   that the output is the same: the LZMA, LZMA2 and PPMd encoders at the
   same settings write the same bytes as the SDK, and whole 7z and xz
   archives are byte for byte the ones `7z` writes with the same switches
   (the tests compare them). When in doubt the reference source wins, not
   this document.
3. **Nothing heavy on the caller's isolate.** Every public operation of
   `SevenZipArchive` and every `...File` helper runs in a background
   isolate. The in memory helpers (`xzCompress`, `sevenZipCompressBytes`...)
   run where they are called, and say so.
4. **Pure Dart.** No FFI, no plugins, no dependencies at run time, so the
   package builds for every native Flutter target unchanged.

## 2. Rules for every file

1. Pure Dart, `dart:io`, `dart:isolate` and `dart:typed_data` only (and
   `dart:convert` for text), no packages at run time.
2. Keep the C/C++ function name in a short comment above each Dart
   function (`// LzmaDec_DecodeReal`). Same algorithms, same constants,
   same bit exact output where the C code is deterministic.
3. Hot loops: `Uint8List`, `Uint16List`, `Uint32List`, `Int32List`, locals
   instead of fields inside loops, no closures, no boxing, no growable
   `List<int>`. Dart ints are 64-bit: mask with `& 0xFFFFFFFF` where C
   relies on UInt32 wraparound. No `>>>` needed on masked values.
4. Synchronous APIs only in `lib/src`, except `api.dart`, `parallel.dart`
   and `pool.dart`.
   Streams are the interfaces in `lib/src/io/streams.dart`. Errors are
   `SevenZipException` (`InvalidArgException` for bad switches).
5. Comments and docs: plain English, US keyboard characters only. No em or
   en dashes, no arrows, no curly quotes. Use commas, colons, parentheses.
6. `dart analyze` clean (package:lints/recommended).
7. Tests in `test/`, small inputs (a few MB at most; the machine is shared
   with other work). Interop against the system `7z` (7-Zip 23.01 at
   `/usr/bin/7z`) and `xz` where it applies, both directions. Tests that
   need them are skipped when they are missing.

## 3. Layers

- `lib/src/io/streams.dart`: `InStream`, `OutStream` and their seekable
  forms (7-Zip's ISequentialInStream, IInStream...), memory and file
  implementations, `SevenZipException`.
- `lib/src/util/crc.dart`: CRC-32 and CRC-64 (7zCrc.c, XzCrc64.c).
- `lib/src/common/method_props.dart`: MethodProps.cpp (PropVariant,
  CoderPropId, CMethodProps, SetParam, StringToDictSize, ParseMtProp2...)
  and StringToInt.cpp, shared by every coder and handler.
- `lib/src/codec`: the codecs.
  - `codec.dart`: coder interfaces, method ids and names, the decoder
    registry (CreateCoder.cpp and the *Register.cpp files).
  - `lzma/`: `lz_find.dart` (LzFind.c), `lzma_dec.dart`, `lzma_enc.dart`,
    `lzma2_dec.dart`, `lzma2_enc.dart`, `lzma_coder.dart` (the adapters
    and property parsing of LzmaEncoder.cpp, Lzma2Encoder.cpp and their
    decoders).
  - `ppmd/`: `ppmd7.dart`, `ppmd7_dec.dart`, `ppmd7_enc.dart`,
    `ppmd_coder.dart` (PPMd var.H with the 7z range coder).
  - `filters/`: `bra.dart` (Bra.c, Bra86.c, BraIA64.c: x86, PPC, IA64,
    ARM, ARMT, ARM64, SPARC, RISCV), `delta.dart`, `swap.dart`,
    `bcj2.dart` (Bcj2.c, Bcj2Enc.c, Bcj2Coder.cpp), `filter_coder.dart`.
  - `copy.dart`, `registry.dart`.
  - `deflate/`: zlib 1.3.1 (`deflate.dart`, `trees.dart`, `inflate.dart`,
    `inftrees.dart`, `zutil.dart`), `infback9.dart` (Deflate64 decoding,
    zlib's contrib/infback9) and `deflate_coder.dart` (the coder shapes).
  - `bzip2/`: bzip2 1.0.8 (`compress.dart`, `blocksort.dart`,
    `huffman.dart`, `decompress.dart`, `bzip2_tables.dart`) and
    `bzip2_coder.dart`.
  - `ppmd8/`: Ppmd8.c, Ppmd8Dec.c, Ppmd8Enc.c (PPMd var.I, zip method 98,
    from the public domain C files of 7-Zip).
  - `lzh/`: the LHA decoders of lhasa (`lha_decoder.dart`,
    `lh1_decoder.dart`, `lh_new_decoder.dart` for lh4 to lh7,
    `larc_decoders.dart`, `pma_decoders.dart`), ARJ method 4
    (`arj4_decoder.dart`), and `lzh_encoder.dart` (lh5, lh6, lh7 and ARJ
    methods 1 to 3, written from the format).
  - `rar/`: the RAR 2.9/3.x decoder and its PPMd variant (after
    libarchive), the RAR5 decoder (after libarchive) and the RAR5 encoder
    (written from the format), `rar_huffman.dart`.
- `lib/src/crypto`: `aes.dart` (Aes.c, CBC), `sha256.dart`,
  `seven_zip_aes.dart` (7zAes.cpp: key derivation, properties, coder),
  `sha1.dart` (Sha1.c), `hmac_sha1.dart` (HMAC and PBKDF2, RFC 2104 and
  2898), `zip_crypto.dart` (PKWARE traditional encryption, APPNOTE),
  `winzip_aes.dart` (WinZip AE-1/AE-2), `rar5_kdf.dart` and `blake2sp.dart`
  (RAR5 keys and file hashes).
- `lib/src/format`: the archive handlers.
  - `archive_types.dart`: PropID.h and IArchive.h (Kpid, OperationResult,
    the extract and update callbacks).
  - `handler_out.dart`: HandlerOut.cpp (CMultiMethodProps and the -m
    switch handling shared by the 7z and xz handlers).
  - `sevenz/`: the 7z handler (7zIn, 7zOut, 7zDecode, 7zEncode, 7zUpdate,
    7zHandler, 7zHandlerOut, 7zProperties, 7zCompressionMode) and
    `sevenz.dart`, the synchronous library facade (`SevenZipReader`,
    `SevenZipWriter.update`).
  - `xz/`: Xz.c, XzDec.c, XzEnc.c, XzHandler.cpp; `XzArchive`.
  - `lzma_alone.dart`: the .lzma and .lzma86 handler and `lzma e`
    (LzmaAlone.cpp, Lzma86Enc.c).
  - `split.dart`: split volumes (SplitHandler.cpp, MultiStream.cpp,
    MultiOutStream.cpp).
  - `gzip/`: the gzip handler (RFC 1952: several members, all the header
    fields; `GzipDecoderInStream` for one pass reading).
  - `bzip2/`: the bzip2 handler (several streams).
  - `tar/`: the tar handler (after libarchive: ustar, GNU and pax headers,
    long names, sparse files; writing GNU or pax, `updateItemsSteps` for a
    tar written into a compressor).
  - `zip/`: the zip handler (after libarchive and APPNOTE: zip64, data
    descriptors, Unicode names, extra time fields, symbolic links; Store,
    Shrink, Reduce, Implode, Deflate, Deflate64, BZip2, LZMA, xz, PPMd;
    ZipCrypto and WinZip AES; writing and updating).
  - `lha/`: the LZH handler (after lhasa; level 0, 1, 2 headers; writes
    level 2 headers).
  - `arj/`: the ARJ handler (ARJ technote; methods 0 to 4 both ways).
  - `rar/`: the RAR handlers ("Rar" for RAR 1.5 to 4.x archives, "Rar5"),
    reading after libarchive, RAR5 writing (`rar5_out.dart`), volumes and
    encryption (`rar_crypto.dart`).
- `lib/src/cli`, `bin/zx.dart`: the command line tool, 7zr's commands and
  switches (ArchiveCommandLine.cpp, Main.cpp, List, Extract, Update...).
  `load_codecs.dart` registers the formats (7zr's plus gzip, bzip2, tar,
  zip, Lzh, Arj, Rar and Rar5) and lists the codecs for `i`;
  `arc_handlers.dart` and the `arc_*.dart` files adapt each handler to the
  IInArchive / IOutArchive shape the UI code calls. `arc_compound.dart`
  makes a tar inside gzip, bzip2, xz or lzma one archive (section 8).
  `platform.dart` holds the `_WIN32` switches (section 9), `file_link.dart`
  the reparse data of Windows links (Windows/FileLink.cpp).
- `lib/src/pool.dart`: worker isolates for one operation.
- `lib/src/parallel.dart`: parallel block encoding (section 6).
- `lib/src/api.dart`: the public, isolate based API.
- `lib/zx.dart`: the exports: the API, and the synchronous building blocks
  (reader, writer, streams, codecs) for callers that run them in their own
  isolates.

## 4. Coder shapes

7-Zip's coders are push or pull depending on the direction; the port makes
them fit one model (see `codec.dart`):

- Decoder: `DecoderFactory(props, inputs, outSize, ctx) -> InStream`. A
  decoder wraps its packed input stream(s) and is itself an `InStream`, so
  any 7z coder graph (for example BCJ2 over four LZMA streams) is decoded
  by wrapping streams recursively.
- Filter (BCJ, ARM..., Delta, SWAP): `FilterCoder` with pull `encoder` and
  `decoder`, so a filter can feed a compressor.
- Compressor (LZMA, LZMA2, PPMd, Copy): `Compressor.encode(in, out)` reads
  its input to the end.
- AES encode: `PushEncoder` wrapping the output.
- BCJ2 encode: one input, four outputs, its own function in `bcj2.dart`.

Progress goes through `ProgressCallback(inSize, outSize)`; a callback that
throws stops the coder, and the exception comes out unchanged.

## 5. Handlers

The handlers keep 7-Zip's interfaces (IInArchive, IOutArchive, the
extract and update callbacks with kpid properties), because the CLI port
needs their exact behavior: `7z l -slt` properties, error flags, the
update rules of 7zUpdate.cpp (sorting, solid block splitting, the filter
analysis of the first 16 KiB, kept and renamed items). The facades
(`SevenZipReader`, `SevenZipWriter`, `XzArchive`, `LzmaAloneArchive`) are a
thin layer over them for library use.

Writing a 7z archive always writes a new file: kept items are copied from
the old archive stream (their packed data is not recompressed), then the
caller renames the new file over the old one, as 7-Zip does.

## 6. Isolates and parallelism

- The caller's isolate only sends a request and receives the result and
  throttled progress events (at most one per 100 ms, plus the last).
- `_run` in `api.dart` spawns one isolate per operation. The operation
  reports every file it writes (`name.zx-part`, renamed at the end) and
  every child isolate it spawns. `SevenZipCancelToken.cancel` kills the
  operation isolate and its children with `Isolate.immediate` priority,
  which interrupts running synchronous code, waits for the exit and
  deletes the registered files. Errors, including `SevenZipException`,
  cross the isolate boundary unchanged.
- **The seams.** The SDK encodes LZMA2 and xz blocks in parallel with
  MtCoder: each block resets the dictionary, the state and the properties,
  so the blocks are independent and the output does not depend on which
  thread encoded them. The port keeps that output (the block split, the
  block headers with sizes) but the codecs are synchronous, so
  `XzEnc._encodeMtBlocks` and `Lzma2Enc._encodeMtBlocks` encode the blocks
  one after the other.
- **Parallel xz.** `xz_enc.dart` splits the xz path in its two halves:
  `xzEncodeMtBlock` (XzEnc_MtCallback_Code, one block) and
  `XzMtBlockWriter` (the stream header, XzEnc_MtCallback_Write, the index
  and the footer). `_encodeMtBlocks` runs them in sequence;
  `parallel.dart` runs the first half in a `WorkerPool`, with blocks
  crossing isolates as `TransferableTypedData` and at most one block per
  worker plus one read ahead in flight, and writes the results in order.
  `xzCompressFile` uses it when the normalized properties have more than
  one block thread. The output is byte identical to the sequential path
  and to `7z a -txz -mmt=N` (`test/api_test.dart`). The properties come
  from `XzHandler.createEncoder`, the same code `updateItems` runs.
- **Not parallel yet (future work).**
  - 7z LZMA2 blocks: the 7z writer calls `Compressor.encode` deep inside
    the synchronous update (7zEncode, 7zUpdate). A synchronous caller can
    not wait for an isolate in Dart, so parallel LZMA2 blocks inside a 7z
    folder would need the update path to become asynchronous (or the
    folder to be read ahead into memory and pre-encoded). The seam is
    `Lzma2Enc._encodeMtBlocks`; the same split as for xz applies.
  - Independent 7z folders (`-ms=off`, `-ms=<size>`): the same limit; the
    folders would be encoded to temporary files by workers and copied in
    order.
  - xz decoding of multi-block files (XzDec's MtDec).
  - The LZMA multithreaded match finder (LzFindMt.c): it does not change
    the output and needs shared memory between threads, which isolates do
    not have.
- Default size (`defaultThreads`): half the processors, 1 to 8, and at
  most 4 on Android and iOS.

## 7. Files on disk

- Every output of the API (a new archive, an extracted file, an xz or lzma
  file) is written as `name.zx-part` and renamed only when it is complete
  (and for extraction, when its CRC matched). A failed or cancelled
  operation deletes its part files; an archive being updated stays as it
  was.
- Stored names are made safe before extraction: no leading `/`, no drive,
  no `.` or `..` components, so an archive can not write outside the
  output folder. Symbolic links (archives made with `-snl`) are created
  after every regular file, so a link can not redirect a later file.
- Adding: symbolic links are followed to files, links to directories are
  skipped (no loops), unless `storeSymlinks` stores them as links like
  `-snl`. POSIX modes are stored in the high attribute bits as 7-Zip does
  (on Windows the plain FILE_ATTRIBUTE_* value: directory, archive,
  read-only); on extraction modification times are restored, modes are
  not (dart:io has no chmod). On Windows stored names get the corrections
  of ExtractingFilePath.cpp (characters Windows does not allow, trailing
  dots and spaces, device names such as `con`).

## 8. Known limits and differences from 7-Zip

- Formats beyond the SDK: gzip, bzip2, tar, zip (jar and the other zip
  extensions), LZH, ARJ, RAR and RAR5 are read and written (RAR: extract
  RAR 2.9, 3.x and RAR5, create RAR5 only). Not supported: the RAR 1.5 and
  2.0 methods, RAR 3.x encryption, RAR7 (version 1 compression), writing
  RAR volumes and recovery records, Deflate64 compression (decoding only),
  ARJ garbled (password) files, and the other formats of the full 7-Zip
  (cab, iso, wim...). Deflate, Deflate64, BZip2 and ZSTD methods inside
  7z archives are not decoded: those items fail with `unsupportedMethod`.
- Compound archives (`arc_compound.dart`) are behavior of the port, not
  of 7-Zip. 7-Zip opens x.tar.gz as a gzip archive holding x.tar, because
  CArchiveLink::Open goes to the next level only with kpidMainSubfile and
  a seekable stream of it. The port adds that level when the archive is
  gzip, bzip2, xz or lzma, and item 0 is named `*.tar` or the archive is
  named `x.tar.*` or x.tgz, x.tbz, x.tbz2, x.txz, x.tlz... (or with `-ttar`,
  or the chain `-ttar.gzip`, tar inside gzip in 7-Zip's order). Reading
  goes through the decoded data in one pass (`getSeqStream`, TarHandler
  OpenSeq), like `-si`; errors of the compressor (CRC, data) are reported
  on the last item and as errors of the archive. Creating runs the tar
  writer in steps (`TarHandler.updateItemsSteps`) as the input of the
  compressor, with no temporary file; updating decodes the tar to a
  temporary file in the `-w` folder (or next to the archive), updates it
  and writes the new compressed archive with 7-Zip's temporary archive and
  rename. `-m` switches go to the compressor, except `-mm=gnu|pax|posix`,
  `-mtm`, `-mtc`, `-mta`, `-mtp` and `-mcp`, which go to tar. `-tgzip`,
  `-tbzip2`, `-txz` and `-tlzma` keep 7-Zip's single level.
- SFX modules, multi-volume creation from the API (the writer supports
  `MultiOutStream`, the CLI exposes `-v`), NTFS alternate streams and
  security descriptors.
- The web platform: archives are files.

## 9. Platforms of the command line tool

The SDK chooses the Windows code of the console program at compile time
(`#ifdef _WIN32`); the port has one build and chooses at run time with
`kIsWin` (`lib/src/cli/platform.dart`). Linux follows the POSIX code and
its output must not change. macOS is POSIX with BSD tools.

- Paths: `kDirSep` is WCHAR_PATH_SEPARATOR ('\\' on Windows),
  `isPathSepar` is IS_PATH_SEPAR (both separators on Windows). Item paths
  of an archive get the Windows form in `Arc.getItemPath` (CArc::GetItem_Path:
  '/' to '\\', a '\\' inside a name to U+F05C); the 7z handler and the
  library keep the stored '/' names, and `handler_out.dart` converts back
  (ReplaceSlashes_OsToUnix). Drive, UNC and "\\\\?\\" prefixes follow
  Wildcard.cpp (GetNumPrefixParts) and FileName.cpp (GetRootPrefixSize,
  GetFullPath, ported in `platform.dart` for MyGetFullPathName).
- Extraction names: ExtractingFilePath.cpp with its Windows branches, and
  g_PathTrailReplaceMode on by default. g_CaseSensitive is false on
  Windows and macOS.
- Errors: `Errno` gives the Win32 codes the Windows build uses in the same
  places, `hresultFromErrno` is HRESULT_FROM_WIN32, and `myFormatMessage`
  gives the FormatMessage text (from dart:io, or a table of the codes the
  port can meet).
- Console: the Windows banner has no ShowProgInfo line; text is written in
  the C runtime text mode ("\\r\\n", "\\r\\n" read as "\\n"); the percent
  line is cleared with '\\r'; the password prompt always says "(will not be
  echoed)". The Dart runtime puts the console in CP_UTF8, so UTF-8 is the
  console code page; `-scc WIN` and `-scc DOS` use the ANSI code page of
  dart:io's `systemEncoding`. dart:io has no synchronous standard output on
  Windows, so `runSevenZipCliProcess` runs the program in a worker isolate
  and the main isolate writes its output. `-bt` prints the global time and
  the peak working set only (no GetProcessTimes). `-stm` is checked and
  logged, the affinity is not set (as on POSIX). `-i#` fails with "Cannot
  open mapping" (no file mappings in dart:io).
- File system: no program is run for times on Windows. Files get their
  modification and access times from dart:io, directories where dart:io
  can set them (it can not on most Windows versions), links not at all.
  The creation time is not set. Attributes come from dart:io: directory,
  archive and read-only (hidden and system can not be read). On
  extraction the read-only, hidden and system bits are set with `attrib`
  after the file is closed, and `DeleteFileAlways` clears read-only with
  it. With `-snl` a link is stored as the reparse data that
  FillLinkData_WinLink makes from the link target, and such data (or a
  POSIX link) is extracted as a link by `Link.createSync`. `-snz` reads and
  writes the Zone.Identifier stream by name. Not ported: NTFS alternate
  streams (`-sns`), security descriptors (`-sni`, the 7z format has
  neither), ConvertToLongNames (8.3 short names in arguments), the "*:\\"
  drive scan, device paths, `-seml`.
- macOS: the lstat times of links come from `stat -f` (BSD) instead of
  `stat -c` (GNU); directory and link times are set with `touch -d` and an
  ISO 8601 time (BSD), then `touch -t` (POSIX, seconds) when that fails;
  OPEN_MAX in the banner comes from `ulimit -n` of a shell (there is no
  /proc). A `chmod` or `attrib` that is missing or fails is reported like
  a failed attribute call of 7-Zip ("Cannot set file attribute") and never
  stops the operation; a failing `touch` is ignored, as 7-Zip ignores a
  failing SetDirTime.

## 10. Allowed sources for the other formats

The package is BSD 3-clause. Code may only be ported from sources whose
license allows that, and the notice of each one goes into LICENSE:

| Source (in `ref/`, not committed) | License | Used for |
|---|---|---|
| `lzma-sdk-26.01` | public domain | 7z, xz, lzma, all SDK codecs, the CLI |
| `7zip-public-domain-c` (only the C files of 7-Zip whose header says public domain) | public domain | PPMd var.I (Ppmd8, zip method 98), HuffEnc, BwtSort |
| `zlib-1.3.1` (including `contrib/infback9` for Deflate64) | zlib | Deflate, Deflate64, gzip |
| `bzip2-1.0.8` | bzip2 (BSD style) | BZip2 |
| `libarchive` | BSD 2-clause (check each file header) | tar, zip, RAR 2.9 to 4 and RAR5 reading, LHA |
| `lhasa` | ISC | LHA decoders |
| Public format documents: PKWARE APPNOTE, RFC 1951/1952, POSIX ustar/pax, WinZip AES (AE-1/AE-2), RAR5 technote, ARJ technote | documents | everything written from a specification |

Never read or copy the LGPL parts of 7-Zip (its CPP handlers and coders for
zip, gzip, bzip2, tar, rar, arj, lzh, deflate), the unRAR source (its
license forbids using it to recreate the RAR compressor), or the GPL ARJ
source. Encoders that no permissive source provides (RAR5, ARJ, LHA) are
written here from the format definition, and verified against the
reference tools in `ref/tools/root/usr/bin` (rar 7.00, arj 3.10, lhasa,
jlha) and the system unzip, gzip, bzip2, tar and unrar.
