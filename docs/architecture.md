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
   `ZxArchive`, `SevenZipArchive` and every `...File` helper runs in a
   background isolate. The in memory helpers (`xzCompress`, `sevenZipCompressBytes`...)
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
4. Synchronous APIs only in `lib/src`, except `api.dart`, `zx_api.dart`,
   `zx_worker.dart`, `parallel.dart`, `pool.dart` and
   `codec/zcm/zcm_parallel.dart` (section 15) (and the isolate
   based API of the vendored zpaq engine, `lib/src/zpaq`, section 14,
   which zx does not call).
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
- `lib/src/util/crc.dart`: CRC-32 and CRC-64 (7zCrc.c, XzCrc64.c);
  `crc32c.dart` (CRC-32C), `xxhash.dart`, `tlsh.dart` (TLSH, section 16).
- `lib/src/version.dart`: the zx version (the banner, the .zx writer and
  the min_reader_version check).
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
    `inftrees.dart`, `zutil.dart`; with `deflate64.dart`, the hash chain
    functions with 32-bit positions, they also write Deflate64, see
    section 8), `infback9.dart` (Deflate64 decoding,
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
  - `zcm/`: the zcm context mixing codec family (section 15).
  - `rar/`: the RAR 2.0 decoder with its audio blocks (after rardecode),
    the RAR 2.9/3.x decoder and its PPMd variant (after libarchive), the
    RAR5 decoder (after libarchive; compression version 1 of RAR 7 after
    rardecode) and the RAR5 encoder (written from the format),
    `rar_huffman.dart`.
- `lib/src/crypto`: `aes.dart` (Aes.c, CBC), `sha256.dart`,
  `seven_zip_aes.dart` (7zAes.cpp: key derivation, properties, coder),
  `sha1.dart` (Sha1.c), `hmac_sha1.dart` (HMAC and PBKDF2, RFC 2104 and
  2898), `zip_crypto.dart` (PKWARE traditional encryption, APPNOTE),
  `winzip_aes.dart` (WinZip AE-1/AE-2), `rar3_kdf.dart` (RAR 3.x keys,
  after rardecode), `rar5_kdf.dart` and `blake2sp.dart` (RAR5 keys and file
  hashes).
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
    (LzmaAlone.cpp, Lzma86Enc.c); the handler also writes .lzma (section
    8).
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
  - `arj/`: the ARJ handler (ARJ technote; methods 0 to 4 both ways;
    garbled files both ways, multi-volume reading and UNIX links from
    black box study of arj 3.10, section 8).
  - `zpaq/`: the zpaq journaling archive handler (`zpaq_handler.dart`,
    `zpaq_update.dart`) over the vendored engine (section 14).
  - `zx/`: the .zx format (section 16): `zx_format.dart` (structures),
    `zx_codecs.dart` (the codec registry), `zx_blocks.dart` (one block,
    the job of a worker), `zx_crypto.dart`, `zx_reader.dart`,
    `zx_writer.dart`, `zx_handler.dart` (IInArchive / IOutArchive).
  - `rar/`: the RAR handlers ("Rar" for RAR 1.5 to 4.x archives, "Rar5"),
    reading after libarchive, RAR5 writing (`rar5_out.dart`, with volumes),
    volume names (`rar_volumes.dart`), encryption (`rar_crypto.dart`) and
    the RAR5 recovery record (`rar5_recovery.dart`, from black box study
    of rar 7.00, see section 10).
- `lib/src/zpaq`: the zpaq engine (libzpaq and zpaq 7.15 in Dart),
  vendored from zpaq-flutter (section 14).
- `lib/src/cli`, `bin/zx.dart`: the command line tool, 7zr's commands and
  switches (ArchiveCommandLine.cpp, Main.cpp, List, Extract, Update...).
  `load_codecs.dart` registers the formats (7zr's plus gzip, bzip2, tar,
  zip, Lzh, Arj, Rar and Rar5) and lists the codecs for `i`;
  `arc_handlers.dart` and the `arc_*.dart` files adapt each handler to the
  IInArchive / IOutArchive shape the UI code calls. `arc_compound.dart`
  makes a tar inside gzip, bzip2, xz or lzma one archive (section 8).
  `nest.dart` opens nested archives and builds the flattened tree of
  `-snest` and `ZxArchive.open(flatten: true)` (section 13).
  `platform.dart` holds the `_WIN32` switches (section 9), `file_link.dart`
  the reparse data of Windows links (Windows/FileLink.cpp).
- `lib/src/pool.dart`: worker isolates for one operation.
- `lib/src/sync_pool.dart`: worker isolates for synchronous code (the .zx
  handler, section 6).
- `lib/src/parallel.dart`: parallel block encoding (section 6).
- `lib/src/api.dart`: the public, isolate based API for 7z, xz and lzma.
- `lib/src/zx_api.dart`: the generic isolate based API (`ZxArchive`) for
  every format of the command line tool, for archive managers: open with
  the detection of the CLI (`ArchiveLink.open`: signatures, extensions,
  compressed tars, split and RAR volumes), the listing with the folders
  implied by the paths, extract (items, paths or folders, with or without
  paths, overwrite policies with a question to the caller), extract to a
  temporary file, read bytes, test, add, delete, rename, create folder,
  set comment (zip, rar5) and create, with progress, cancellation and
  password questions; nested archives (`openNested`, `open(flatten:
  true)`, section 13). `zx_worker.dart` is its worker side: it runs the
  handlers through the CLI's `InArchive` adapters with its own extract
  and update callbacks (part files, per item errors, links after every
  file, the update plan of kept, renamed and new items given to
  `updateItems`, as Update.cpp does). `zx_estimate.dart` (synchronous)
  holds `ZxCompression` (`ZxOptions.compression`, turned into the zx
  switches of section 15) and `zxEstimate`, which `ZxArchive.estimate`
  runs with `Isolate.run`.
- `lib/zx.dart`: the exports: the API, and the synchronous building blocks
  (reader, writer, streams, codecs) for callers that run them in their own
  isolates.
- `app/`: the desktop archive manager (Flutter, package `zx_app`), a user
  of `ZxArchive` only (section 11).

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

- `ZxArchive` (zx_api.dart) runs each operation in its own isolate the
  same way, and the worker can ask the caller's isolate a question
  (password, overwrite) through a reply port. The handlers ask for
  passwords synchronously, and a synchronous worker can not wait for an
  answer, so the worker asks before the synchronous part when it can
  (encrypted items in the listing, existing files for the overwrite
  decisions, which are all asked before anything is written); when a
  handler asks unexpectedly, the synchronous part is unwound, the question
  is asked, and the operation goes on without the items already done (an
  update starts again with a new part file). A wrong password found at
  extraction asks again and extracts the failed items again. The listing
  goes to the caller with `Isolate.exit` (no copy); it goes back to a
  worker only for a compressed tar, whose listing would need decoding the
  whole archive again.
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
- **Parallel .zx blocks.** The .zx handler codes blocks in parallel
  although it is synchronous: `SyncJobPool` (`sync_pool.dart`) spawns an
  isolate per block job with the block in the spawn message (isolates
  start without the event loop of the caller), and the isolate writes its
  result to a file in a private temporary folder, which the handler polls
  while it waits (sleeps of 0.1 to 20 ms). At most `threads` jobs are in
  flight; results are written in order, so the output is the same with
  any number of threads (`test/zx_format_test.dart`). Extraction decodes
  the blocks ahead in the order the items use them. The folder is
  registered with the operation (`syncPoolRegisterDir`), so a cancelled
  `ZxArchive` operation deletes it. With one thread, or when no temporary
  folder can be made, the jobs run inline. The async `WorkerPool` would
  need the caller's event loop, which a handler does not have.
- Default size (`defaultThreads`): half the processors, 1 to 8, and at
  most 4 on Android and iOS. The .zx writer and reader also keep the
  estimated memory of their block workers under a limit
  (`zx_memory.dart`: `zxWorkerMemory` from the chain's settings,
  `zxDecodeMemory` from the props of a block's chain): `-mmemuse` or
  `ZxOptions.memoryLimit`, by default min(75% of MemAvailable,
  MemAvailable minus 1.5 GiB) from zcm's probe (`zcmProbeMachine`,
  `zcmUsableBytes`). The writer lowers its worker count (with a warning
  when `-mmt` asked for more); the reader starts a decoder only while
  the ones in flight fit (one always runs).

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
- `ZxArchive` follows the same rules, and also restores POSIX modes (with
  the batched `chmod` of `fs_utils.dart`, as the CLI does), folder times
  (with `touch`, children first) and the access time of files. A link is
  created only when its target stays inside the output folder and its
  path does not go through another link (CheckLinkPath_in_FS); a hard link
  of tar is extracted as a copy of its target. An update of a compressed
  tar decodes the tar into a temporary folder `.zx-*` next to the archive,
  deleted at the end or when the operation is cancelled. Volumes of a new
  archive are registered one by one and deleted if the operation fails.

## 8. Known limits and differences from 7-Zip

- Formats beyond the SDK: gzip, bzip2, tar, zip (jar and the other zip
  extensions), LZH, ARJ, RAR and RAR5 are read and written (RAR: extract
  RAR 1.5, 2.0, 2.9, 3.x and RAR5 with the RAR 1.5, RAR 2.0, RAR 3.x and
  RAR5 encryption of data and headers, create RAR5 only). The RAR 1.5
  method (unpack version 15, `rar15_decoder.dart`) and the RAR 1.5 and 2.0
  ciphers (`rar_legacy_cipher.dart`) are independent implementations:
  written from format descriptions (the prose and tables of the
  rar-research documents, section 10) and black box tests with RAR 1.55
  for DOS (under DOSBox), WinRAR 2.90 and unrar, not from any decoder's
  code. RAR 1.5 has no solid flag per file: in a solid archive every
  compressed file after the first continues the stream. A non ASCII
  password of these ciphers is taken in code page 437 (what the DOS and
  console versions used; unrar on Linux uses UTF-8 and fails on such
  archives), or as UTF-8 when it has other characters. Not supported: the
  ARJCRYPT
  ciphers of ARJ (`-hg`, encryption version 2 and up: `unsupportedMethod`),
  ARJ multi-volume creation, and the other formats of the full 7-Zip
  (cab, iso, wim...). Deflate, Deflate64, BZip2 and ZSTD methods inside
  7z archives are not decoded: those items fail with `unsupportedMethod`.
- RAR beyond 7-Zip's switches (behavior of the port): RAR 7 archives
  (compression version 1: dictionaries above 4 GB, fractional sizes, 80
  distance slots) are extracted; the window is reduced to the size of the
  data, and at most 4 GiB is allocated. The >4 GB distance path follows
  rardecode and could not be checked against rar output (rar 7.00 needs
  far more memory than this machine has to write such an archive); the
  table layout is checked by unrar and rar on archives written with
  `-malgo=1`. `-v<size>` with the Rar formats writes RAR5 volumes named
  as rar names them (`name.part1.rar`, with as many digits as the input
  size needs; one volume is renamed `name.rar` with the flags of a plain
  archive), every volume but the last exactly `<size>` (zero padded after
  its end header, as rar does). `-mrr=<n>[%]` adds a recovery record of
  n percent (to each volume) that `rar t` checks and `rar r` repairs with;
  it needs an output that can be read back (a file, not stdout).
  `rar5Repair` (`rar5_recovery.dart`) repairs an archive or volume in
  memory with its record (the library has it, the CLI has no repair
  command, as 7-Zip). Not written: the quick open record and the locator
  of the main header (both optional), recovery volumes (`.rev`).
- ARJ beyond the technote (behavior of the port, from black box study of
  ARJ32 3.10, see `arj_header.dart`): garbled files (`-g<password>`, the
  XOR garbling) are read and written with `-p`; a wrong password shows
  as a CRC or data error, as for 7-Zip's weak ciphers. Multi-volume
  archives (x.arj, x.a01 ... x.a99, x.100 ...) are read when the first
  volume is opened: the parts of a split file are one item (its CRC is
  checked for each part); opened from a later volume, a file that starts
  before it is `unavailable`; they can not be updated. UNIX special files
  (`arj -a1`) are read: symbolic links as links, hard links as
  `kpidHardLink`, FIFOs as empty files; `-snl` writes symbolic links as
  arj does (file type 6, host UNIX).
- Creating .lzma files (`zx a x.lzma file`, `x.tar.lzma`, `x.tlz`): 7-Zip
  can not (LzmaHandler.cpp has no IOutArchive). The port's UpdateItems
  writes the stream of `lzma e` with the properties of the LZMA method of
  `-m` (`-mx`, `-md`, `-mfb`, `-mlc`, `-mlp`, `-mpb`, `-mmf`, `-meos`...)
  and the size in the header, written after the data when the output can
  be seeked; to stdout (`-so`) the size is unknown and the stream ends
  with the end marker. .lzma86 is read only.
- Deflate64 compression (zip `-mm=Deflate64`) is zlib's deflate with the
  64 KiB window, distance codes 30 and 31 and matches of at most 257 bytes
  (the longest 7-Zip's Deflate64 encoder writes, which keeps code 285 and
  its 16 extra bits unused). As with Deflate, the output is zlib's, not
  7-Zip's (a few percent larger than 7-Zip's optimal parsing).
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
- SFX modules, multi-volume creation from `SevenZipArchive` (the writer
  supports `MultiOutStream`, the CLI exposes `-v`, `ZxArchive.create` has
  `volumeSize`), NTFS alternate streams and security descriptors.
- `ZxArchive` updates: multi-volume archives, RAR 1.5 to 4.x archives,
  archives after a stub (SFX) or with data after their end can not be
  updated (`capabilities` says so); gzip, bzip2, xz and lzma hold one file
  (only gzip can rename it); comments are written for zip and RAR5 only.
  Adding keeps the old items of an encrypted archive encrypted, and
  encrypts the new ones only with `ZxOptions.password`.
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
| `libarchive` | BSD 2-clause (check each file header) | tar, zip, RAR 2.9 to 4 and RAR5 reading, LHA, cpio reading |
| pakler 0.2.0 (github.com/vmallet/pakler, the installed Python package) | MIT | the Reolink PAK layout, section count rule and checksum |
| zpaq-flutter (the author's own port; libzpaq and zpaq 7.15 by Matt Mahoney, public domain; zpaqfranz by Franco Corbelli, MIT; divsufsort by Yuta Mori, MIT; scrypt after Colin Percival, BSD 2-clause) | BSD 3-clause here (same author), notices in LICENSE | zpaq (section 14) |
| `rardecode` (github.com/nwaples/rardecode) | BSD 2-clause | RAR 2.0 decoder (unpack 20 and 26, audio blocks), RAR 3.x AES key derivation and encrypted headers, the CRC range of old comment blocks, RAR5 compression version 1 (RAR 7) |
| `lhasa` | ISC | LHA decoders |
| `tlsh` (github.com/trendmicro/tlsh, the paper and the reference implementation's constants) | Apache 2.0 or BSD 3-clause, used under BSD | the TLSH digests of .zx entries (`lib/src/util/tlsh.dart`), checked against its `tlsh_unittest` tool |
| bitplane/rar-research (github.com/bitplane/rar-research), the prose, tables and cipher definitions of its `doc/` files only | format facts, no code taken | the RAR 1.5 method and the RAR 1.5 and 2.0 ciphers, written here as new code and checked black box (RAR 1.55, WinRAR 2.90, unrar) |
| `paq8px` (github.com/hxim/paq8px, cloned in `ref/paq8px`), lpaq1 and paq8l (Matt Mahoney), `cmix` v21 (`ref/cmix`, Byron Knoll, with fxcm by kaitz) | GNU GPL (paq8px, lpaq1, paq8l: GPL v2 or later; cmix: GPL v3). The owner decided that zcm may use their models, parameters and code; see the note in section 15 | the zcm codec (`lib/src/codec/zcm`, section 15) |
| Public format documents: PKWARE APPNOTE, RFC 1951/1952, POSIX ustar/pax, WinZip AES (AE-1/AE-2), RAR5 technote, ARJ technote, Devicetree Specification (devicetree.org), the U-Boot legacy image header layout and its os/arch/type/comp codes (format facts, checked black box with mkimage), the lzop file layout, the UEFI Specification (GPT), Microsoft's FAT specification (fatgen103), the Linux kernel's Documentation/filesystems/ext4, the SquashFS format write-up of dr-emann (dr-emann.github.io/squashfs), the cramfs README and documentation (Linux fs/cramfs, Documentation/filesystems/cramfs), the JFFS2 paper (David Woodhouse, "JFFS: The Journalling Flash File System", 2001) | documents | everything written from a specification |

Source policy: the early releases avoided the sources below. Since
2026-09-27 the owner has decided that zx may draw from any source
(paq8px, cmix, zpaq and others), as new Dart code under the project
license, with the original authors credited in each file, the README and
LICENSE. The list below is kept as a record of how the earlier formats
were written.

Earlier rule: never read or copy the LGPL parts of 7-Zip (its CPP handlers and coders for
zip, gzip, bzip2, tar, rar, arj, lzh, deflate), the unRAR source (its
license forbids using it to recreate the RAR compressor), The Unarchiver
(XADMaster, LGPL), unarr (LGPL), ports of any of them (junrar,
SharpCompress's RAR decoders, omnizip-rar), code of specifications
written with them as a reference (the rars crate and any code in
bitplane/rar-research, which name XADMaster and, in their history, the
unRAR derived Rar decoders of 7-Zip as references; the format facts that
its documents state in prose and tables were used for the RAR 1.5 method
and ciphers, at the owner's direction, and nothing was translated), or
the GPL ARJ source. Encoders that no permissive source provides (RAR5, ARJ, LHA) are
written here from the format definition, and verified against the
reference tools in `ref/tools/root/usr/bin` (rar 7.00, arj 3.10, lhasa,
jlha) and the system unzip, gzip, bzip2, tar and unrar. Formats that no
permissive source or document describes (the RAR5 recovery record) are
derived by black box study of what the reference tools write and accept:
archives made by rar are compared field by field and with controlled
input differences, never by reading or disassembling their code.

## 11. The desktop app (`app/`)

- It uses the public API (`package:zx/zx.dart`, `ZxArchive`) and nothing
  below it: every archive operation runs in the operation's isolate, the
  UI isolate sends the request, redraws from the throttled progress and
  answers the questions (password, overwrite) with dialogs. The progress
  dialog waits while a question is on screen, so it never covers it.
- Nothing blocking on the UI isolate: file system calls are the async
  forms (`exists()`, `create()`, `stat()`...), no `...Sync` call in
  `app/lib`. The per folder work (children, sort, filter, folder sizes) is
  derived lazily from the listing and cached until the next change; the
  preview reads at most 512 KiB with `readBytes` and cancels the read when
  the selection changes.
- The outside world (launcher, file dialogs, the folders of the desktop)
  is behind `AppServices`, so the tests replace it and never touch the
  real desktop.
- The desktop integration (`app/lib/src/integration.dart`) is per user
  and reversible: it edits only its own entries (the zx lines of
  mimeapps.list, restoring the previous defaults; its own action in
  Thunar's uca.xml), and keeps a `*.zx-backup` copy of a user file before
  changing it the first time. The settings switches, the
  `--install-integration` / `--remove-integration` flags and
  `tool/install_linux.sh` share it.
- Nested archives (section 13): the app opens a file item as an archive
  only after `ZxArchive.probeNested` (the worker reads the start of the
  item and checks the registered signatures; an item of a container is
  tried with the full detection), so a text file is never handed to the
  formats without a signature and a document that is a zip inside
  (docx, odt, epub, jar...) opens with its program unless "Open as
  archive" is chosen. Each level is an `ArchiveModel` with `parent` (the
  level it was opened from) and `entry` (the item); a nested archive
  holding a single archive is shown as the same level (`passed`: a UBI
  image with one UBIFS volume). The path bar and the title show the
  chain, Back and Up leave a level, and a level's handles are closed
  (`ZxArchive.close`, which deletes the temporary copies) when it is left
  or replaced. Nested levels, the flattened view (View, "Show inner
  filesystems", `ZxArchive.open(flatten: true)`) and an older zpaq
  version are read-only: `ArchiveModel.readOnlyReason` is the tooltip of
  the disabled actions.
- zpaq versions: the status bar selector and the Archive menu open the
  archive again with `ZxArchive.open(version:)`; the model keeps the list
  of every version (`allVersions`), since a handle at version N lists
  only the versions up to N.
- Same text rules as the library: plain ASCII in comments, docs and
  strings of the UI.

## 12. Format detection

A file's name is only a hint. `ArchiveLink` (`lib/src/cli/open_archive.dart`,
the port of OpenArchive.cpp) opens every file in this order, for the CLI,
`ZxArchive` and the desktop app alike:

1. The format its extension names, if its signature or `IsArc` check agrees.
2. Every format whose signature matches at the file start (or, for
   formats with `findSignature`, anywhere in the first part of the file:
   self-extracting and prefixed archives).
3. The formats without a signature (lzma, lzma86, old v7 tar...) by
   trying their `IsArc` check and `Open`.

So a 7z named `.txt`, a rar with no extension or a zip behind an .exe stub
all open as themselves (`test/detect_test.dart`).

Nested archives (section 13) use the same detection on the stream of the
item. An item of a container format is always tried with all of it; any
other item first has its start compared with the registered signatures
(and their `IsArc` checks), at the signature offsets (the tar magic at 257,
ISO 9660 and UDF at 32 KiB); only a match is opened, so a text file never
reaches the formats without a signature.

Disc images follow 7-Zip's one exception to this order: when the
extension names both Iso and Udf (`x.iso`, `x.img`), Udf is tried first,
so an ISO/UDF bridge disc opens as UDF; without such an extension the
signature pass finds Iso first, as 7-Zip does (`test/iso_test.dart`).

Compressed tars need one more step, because the outer layer (gzip, bzip2,
xz, lzma) is a valid archive on its own. The tar level is opened when the
archive name says so (`x.tar.gz`, `x.tgz`...), when the stored name ends in
`.tar`, or, failing both, when the first 512 decoded bytes are a valid tar
header (`sniffCompoundTar` in `arc_compound.dart`). The last case covers
`tar czf - dir > file` and renamed files. `-tgzip` (and the other outer
types) still opens only the outer level, as in 7-Zip.

When adding to an existing file whose name has no extension, 7-Zip's rule
applies: `zx a name files` creates `name.7z`. Use `-sae` (exact name) to
update the file in place in whatever format it was detected as.

## 13. Nested archives (zx extension)

Firmware and disk images hold images: the sections of a Reolink pak are
a loader, a device tree, U-Boot, a uImage kernel and UBI images whose
volumes are UBIFS file systems; a disk image has partitions with FAT or
ext file systems. 7-Zip opens one level (and a second one only through
kpidMainSubfile). zx adds, outside the 7-Zip code paths:

- `ArcInfoEx.isContainer`: formats whose items are images (Pak, UImage,
  Ubi, MBR, GPT). Every file item of a container, and the item of a
  compressor opened from one, is tried with the full detection of
  `ArchiveLink` (section 12). Any other file item is tried when its first
  bytes match a registered signature.
- `lib/src/cli/nest.dart`: `FlatArc`, an `InArchive` over one virtual
  read-only tree. Each item that opens as an archive, without errors,
  becomes a folder holding the tree of its inner archive; the rest stay
  files. The nested archive reads its item through the handler's
  `getStream` (IInArchiveGetStream, random access without a copy: pak
  sections, UBI volumes, partitions, tar, iso, the file systems); a
  handler without it (7z, rar) is read in one pass that keeps the start
  of each item and copies the ones that may be archives to temporary
  files. Rules:
  - A nested archive with one item that is itself an archive shows that
    archive: `rootfs/` of the pak holds the UBIFS files, not
    `rootfs/rootfs.ubifs/`. A UBI image with several volumes keeps a
    folder per volume. The archive that was opened keeps its items.
  - An item that opens only as a compressor or a device tree (gzip,
    bzip2, xz, lzma, Fdt) inside a file system stays a file: `x.gz` and
    `x.dtb` are data there. From a container they open (the fdt section
    of the pak shows its nodes and `fdt.dts`).
  - Depth limit (default 4) and a cycle guard: an archive with the format
    and the size of one of its parents is not opened again.
  - Extraction maps the items of the tree back to their archives, grouped
    per archive, so each handler extracts in its own order; hard link
    targets get the folder of their archive.
- CLI: `-snest[N]` for `l`, `t`, `x` and `e` sets `OpenOptions.nestDepth`;
  `ArchiveLink.open` then replaces the archive of the last level with a
  `FlatArc`, so list, extract and test run unchanged. Without it nothing
  changes (7-Zip's one level; `-t` chains as before). `h` hashes files on
  disk, so the switch does not apply to it.
- Library: `ZxArchive.open(path, flatten: true, maxDepth: 4)` lists the
  tree (`ZxItem.nestedFormat` on the folders of nested archives,
  `ZxItem.nestChain` on every item) and extracts, tests and reads through
  it; the operations open the same nested archives again from the layout
  found at open (no second search). `ZxArchive.openNested(item)` opens one
  item as an archive of its own, with `parent` and `nestPath` for a UI
  that goes into it and back; it reads the item in place, or from a
  temporary copy when the parent has no random access. Nested and
  flattened handles are read only; `close()` deletes their temporary
  files. `ZxArchive.probeNested(item)` says, before that, whether an
  item looks like an archive: the name of the format whose signature (and
  IsArc check) matches its start (`NestSniffer.formatOf`), for an item of
  a container the format the full detection finds, else null. It reads
  only the start of the item (through `getStream`, or decoded into memory
  when the handler has no random access).
- Hard links: the CLI and the library create real hard links (`ln`, or
  `mklink /H` on Windows) and copy the file where the file system can not
  link.

## 14. zpaq (zx extension)

zpaq journaling archives are read and written with the zpaq engine of
zpaq-flutter, the author's pure Dart port of libzpaq, zpaq 7.15 and the
zpaqfranz attribute format (its own `docs/architecture.md` describes the
format and the port).

- **Vendored, not a dependency.** `lib/src/zpaq` is a copy of
  zpaq-flutter's `lib/src` (same layout, `lib/zpaq.dart` as `zpaq.dart`),
  and its small tests are `test/zpaq_*_test.dart`. zpaq-flutter stays the
  upstream: changes are made there and copied with `tool/sync_zpaq.sh
  [../zpaq-flutter]`, which gives each file the zx license header (the
  third party notices are in LICENSE and, for divsufsort, in the file) and
  rewrites the package imports. Do not edit the copies. The engine's
  isolate based API (`api.dart`, `pool.dart`, the parallel paths of
  `add.dart` and `extract.dart`) comes along but zx does not call it.
- **Handler** (`lib/src/format/zpaq`, adapter `lib/src/cli/arc_zpaq.dart`,
  format "zpaq", extension `.zpaq`). Signature: the 13 byte locator tag
  zpaq writes before each block (`37 6B 53 74 A0 31 83 D3 8C B2 28 B0
  D3`), or a block header without it (`zPQ`, level 1 or 2, type 1;
  `isArcZpaq`). An encrypted archive starts with 32 random bytes of salt,
  so it has no signature: it opens by its extension (or `-tzpaq`), after a
  password; a file named `.zpaq` that starts with the magic of another
  common format is not asked a password. Open reads the index through the
  stream the UI gives (`ZpaqStreamInput`, decrypting by absolute offset),
  not a file path, so nested archives work.
- **Items and versions.** The items are the files and folders of the last
  version (or of version N set before Open: `-mversion=N`,
  `OpenOptions.version`, `ZxArchive.open(version:)`), sorted by name.
  Properties: path, size, mTime (seconds, UTC), attributes (zpaq's `u`
  POSIX mode as 7-Zip's unix extension, or `w` Windows attributes), the
  CRC-32 of the zpaqfranz attributes when present, `Method` (what the
  block header says: Store, LZ77 or CM; the zpaq method number is not
  stored), and `Version` (ZxKpid.version: the version that wrote the
  item). Archive properties: `Versions` (ZxKpid.numVersions), `Version`
  (the one shown), the methods of its blocks, and a warning when the last
  update was interrupted (it is ignored, like zpaq does, and the next
  update overwrites it). Extraction decodes each data block once while
  items still need it (at most 192 MiB of decoded blocks cached), checks
  every fragment against its SHA-1 and each file against its CRC-32 when
  stored; `getStream` gives random access by fragment.
- **Update** (`zpaq_update.dart`) is zpaq's `add` for one thread, fed by
  the update callback: the old archive is copied byte for byte into the
  new file (zx writes every update to a new file and renames it, as
  7-Zip does; an encrypted one too, since the key stream only depends on
  the offset), then one version is appended: new and changed files are cut
  by zpaq's rolling hash, fragments already in the archive are
  deduplicated, blocks are built and compressed with zpaq's heuristics
  (the data blocks are byte for byte the ones zpaq 7.15 writes with one
  thread), kept items cost nothing, renamed items reuse their fragment
  lists (no recompression) with a deletion of the old name, and the items
  left out are written as deletions. No change, no version. `-mx=0..5`
  (default 1), `-mm=<method>`, `-mfragment=N`, `-mhash=xxh64|sha1|off`;
  `-p` encrypts only a new archive (an existing one keeps its key; a
  different password is an error); an archive opened at an older version
  is not updated.
- **Not parallel.** UpdateItems and Extract are synchronous and run on the
  operation's isolate (the CLI process, or the `ZxArchive` worker), block
  after block; the engine's worker pools need `await`, which the handler
  interfaces do not allow (section 6). `-mmt` is accepted and ignored.
  Updating copies the old archive once per update (the price of the
  temporary file and rename); appending in place would need an update
  path that writes to the archive itself.
- Not supported (as in zpaq-flutter): streaming format archives (zpaq
  `-method s`, opened as "not an archive"), multi-part archives
  (`name????.zpaq`) and index files, zpaqfranz's "franzen" encryption.

## 15. zcm (context mixing, experimental)

`lib/src/codec/zcm` is a family of context mixing codecs (paq8 style)
with nine strengths, for the .zx container (experimental codec id
0x10000, docs/zx-format.md section 11). It is not a port of one program:
the components follow paq8, lpaq1, paq8px and cmix, rewritten in Dart
around one predictor, and the file headers name their sources.

- **Files.** `zcm.dart` (options, the stream format, `ZcmCompressor`,
  `ZcmDecoderStream`, `zcmDecoder`, the segment coding, the x86 E8/E9
  transform), `zcm_detect.dart` (the data types: text, x86, binary per
  64 KiB block; BMP (1, 4, 8 bits gray or palette, 24, 32), PBM, PGM,
  PPM, WAV and AIFF by their headers; raw images without a header by
  their row period),
  `zcm_dict.dart` and `zcm_dict_words.dart` (the English dictionary
  transform of cmix and its word list, deflated and base64 encoded,
  inflated on first use; `tool/zcm_gen_dict.dart` regenerates it), `zcm_coder.dart` (the 32-bit
  carryless binary arithmetic coder of paq8/lpaq, 16 bit
  probabilities), `zcm_tables.dart` and `zcm_state_table.dart` (squash,
  stretch, ilog, reciprocals, the paq8px nonstationary state table),
  `zcm_components.dart` (StateMap, the lpaq APM and the paq8px APM,
  APM1 and APMPost, the two layer Mixer, the hashed ContextMap with byte
  history and skipped contexts, DirectMap), `zcm_models.dart` (the
  order-n models, match, word/text, sparse, indirect, record, char
  groups, x86 contexts, DMC), `zcm_words.dart` (the paq8px word and line
  model, chart, nest and XML models), `zcm_text.dart` (paq8px's text
  model with its English stemmer and word classes), `zcm_match.dart`
  (paq8px's match model: four candidates, recovery after a one byte
  mismatch, minimum lengths per data type), `zcm_maps.dart` (paq8px's
  StationaryMap, LargeStationaryMap, SmallStationaryContextMap,
  IndirectContext, MTFList and ResidualMap), `zcm_sparse.dart`
  (paq8px's sparse match, sparse bit, linear prediction and similarity
  models; ported, tested and measured, see docs/performance.md), `zcm_x86.dart` (the paq8px x86
  parser), `zcm_image.dart` (images: residual histograms, paq8px's six
  least squares fits per plane, neighborhood and palette contexts, the
  1 and 4 bit image model), `zcm_audio.dart` (PCM audio: least
  squares and LMS predictors, residual contexts), `zcm_ols.dart` (the
  least squares fit), `zcm_byte_models.dart` (PPMd var.H of
  `lib/src/codec/ppmd` and the LSTM as byte predictors), `zcm_lstm.dart`,
  `zcm_math.dart` (deterministic exp, tanh, logistic, sqrt),
  `zcm_fast.dart` (the level 1 predictor, one class),
  `zcm_predictor.dart` (the level table, the memory split, the mixer
  selectors and the SSE chains), `zcm_auto.dart` (settings from the
  machine), `zcm_parallel.dart` (independent segments on worker
  isolates; the only asynchronous file, rule 4). `ZcmCompressor(threads:
  N)` codes independent segments on the synchronous pool of
  `lib/src/sync_pool.dart` with the same output.
- **Stream version 1 (zcm 1.0).** zcm is experimental: the version
  stays 1 when the output changes (the golden hashes of
  `test/zcm_test.dart` are updated instead), and other versions are
  refused. A chunk is a series of segments, each with its
  type, length and (images, audio) layout coded in the arithmetic stream,
  so the decoder does not run the detector. x86 segments go through the
  E8/E9 transform, 16-bit little endian audio is coded most significant
  byte first, and a text segment whose words are mostly English goes
  through the dictionary transform when its inverse gives the text back
  exactly (the encoder checks it). The final probability has 16 bits.
- **Levels.** 1: `ZcmFastPredictor` (orders 1 to 6 in nibble tables,
  match, one mixer set, one APM); 2 to 5: orders 2, 3, 4, 6 with bit
  histories, the word model (5, 10 or 16 contexts), exe contexts (the
  paq8px x86 parser from 4), sparse contexts from 4, light image and
  audio models from 3; 6: more orders, indirect, record, char groups,
  the full x86 parser, the full image and audio models; 7: byte history
  inputs, the paq8px word model and match model, paq8px's mixer
  selectors and SSE chains; 8: word contexts on binary data too and the
  paq8px text model on text (its state also feeds the text SSE chain); 9: PPMd (its memory
  beside the budget) and DMC behind a quick gain check (`ZcmGainGate`:
  their inputs are zero while their own predictions save less than about
  1/32 bit per bit, so compressed data does not lose), paq8px's
  similarity model pair on binary and x86 data, and the optional LSTM
  (`lstm=small|medium|large` or C/L/H). The chart, nest and XML models
  are ported but no level uses them (they did not pay on the benchmark
  corpora, docs/performance.md).
- **Determinism.** A stream must decode on every machine, so the model
  computes the same bits everywhere: integers for every paq style part
  (states, StateMaps, APMs, fixed point mixer weights; 32-bit wraparound
  masked explicitly), doubles with +, -, *, / and the functions of
  `zcm_math.dart` only for the LSTM, the PPMd distribution and the least
  squares and LMS predictors of images and audio, always in a fixed
  order (IEEE 754 defines those exactly, Dart does not fuse multiply and
  add; dart:math exp, log, tanh and pow are never used), tables built
  with integers, and every parameter of the model (level, memory budget,
  flags, LSTM size) in the stream header. Golden hashes in
  `test/zcm_test.dart` pin the output of every level. The code relies on
  64-bit ints (the native VM; not for the web).
- **Memory.** Every table takes its size from the budget in the header
  (`ZcmPredictor`, and `tableBytes` counts them all, the match model's
  context map and maps too): the history buffer, the match tables, the SSE chains,
  then the context maps in proportion to their contexts (DMC and PPMd
  only with 16 MiB or more; PPMd gets a quarter of the budget on top of
  it at level 9); the sizes are
  powers of two, so a model uses between half and all of the budget. The
  image and audio models are built on the first segment of their type and
  may add a quarter of the budget each. The encoder lowers the budget for
  small inputs (`zcmTableBytesPerInputByte`: 64 bytes per input byte
  plus 8 MiB at levels 1 to 5, 256 at 6, 1 KiB at 7, 2 KiB at 8 and 9)
  and stores what it used.
- **Hot loops** follow rule 3: typed lists, the tables of a component in
  locals, inputs written straight into the mixer's `Int32List`, no
  closures on the bit path. The mixer multiplies only the nonzero inputs
  (two weight sets per pass), the context map learns and looks up in one
  pass and adds the inputs in a second one, and the hot functions are
  marked `vm:unsafe:no-bounds-checks`: their indices come from masks and
  from the mixer selectors, which assert their ranges in tests.
- **Credits.** zcm uses the state table, parameters and designs of
  paq8px, lpaq1, paq8l and cmix, credited in each file, in the README and
  in LICENSE. It is new Dart code distributed as part of zx under the
  project license, by the owner's decision (section 10). The .zx registry
  (`lib/src/format/zx/zx_codecs.dart`, `_registerExperimentalCodecs`)
  registers it as codec 0x10000.
- **In .zx.** `-m0=zcm[:params]` (params as `zcmOptionsFromString`:
  `level=N` or a level name, `mem=`, `lstm[=C/L/H|small|medium|large]`,
  `seg=`, `nodetect`, `nodict`; the archive level is the default zcm
  level). Each .zx block is one zcm stream with its own model; the
  container codes blocks in parallel, so memory is about threads times
  the zcm budget (capped per block by `zcmTableBytesPerInputByte` plus 8
  MiB).
- **Automatic settings in .zx** (`lib/src/cli/zx_zcm_auto.dart`, zx
  switches): `-m0=zcm:auto`, `-mtime`, `-mmem`, `-mlstm`, `-mcal` and the
  named `-mx` levels are read by `ZxArc.setProperties`
  (`zxPrepareZcmProperties`) before the handler sees the properties, so
  `lib/src/format/zx` never parses them: the auto method becomes a plain
  `zcm` placeholder, and `ZxArc.updateFile` / `updateItems`, once the
  size of the new data is known from the update callback, runs
  `zxPlanZcm` (`zcmAutoSelect` with the memory budget imposed through a
  `ZcmMachine`, then one .zx block per worker of at most 64 MiB, the
  budget of each stream refitted to the block) and gives the handler an
  explicit method (`zcm:level=6:mem=1024`), `-mmt` and `-mbs`. The memory
  of a worker is the estimate of the .zx memory guard (`zxWorkerMemory`
  of `zx_memory.dart`) and the budget is `-mmem` or the guard's limit
  (`-mmemuse`, by default the same safe maximum), so the guard never cuts
  the workers of a plan: the model budget is lowered (to a quarter at
  most while several workers run), then the workers are halved. With
  `-mmem` above the guard's limit the plan passes `-mmemuse` too. The
  archive holds only those settings, so the output does not depend on the
  machine that decodes it, only the choice depends on the machine that
  writes it. The CLI prints `ZxZcmPlan.summary` before compressing
  (`UpdateCallbackUI2.zxInfo`, -bb0; the details at -bb1) and the reason
  of a bad switch (`zxError`). `ZxArchive.estimate` (`lib/src/
  zx_estimate.dart`) makes the same plan without compressing, with the
  speed measured by coding a 64 KiB sample of the input at level 3; its
  `ZxEstimate.compression` pins the plan so that the update does what
  was shown.

## 16. The .zx format (zx extension)

`.zx` is zx's own container, specified in `docs/zx-format.md` (normative,
with the changes made while implementing it in its section 15) and
designed in `docs/zx-format-design.md`. It is not in 7-Zip; the code is
written from the specification, so rule 2 (a C name above each function)
does not apply to it.

- **Files** (`lib/src/format/zx`): `zx_format.dart` (vints, records, the
  Header and its compatibility check, block headers, chains, entries, the
  Index, the Footer and the volume trailer: encoding only),
  `zx_codecs.dart` (the registry: id, name, "introduced in", encoder and
  decoder over whole blocks, wired to the codecs of `lib/src/codec` and to
  the vendored zpaq engine; `registerZxCodec` is the seam of experimental
  families such as zcm, section 15), `zx_blocks.dart` (the block check,
  the chain and the encryption of one block: the jobs of the workers,
  sendable arguments only), `zx_crypto.dart` (scrypt of the vendored zpaq
  engine, AES-256-CTR over `aes.dart`, HMAC-SHA-256), `zx_reader.dart`
  (the last valid Footer, generations, volumes found by their header),
  `zx_writer.dart` (the block pipeline, solid packing, deduplication,
  streamed inline records, volumes with destination folders, appends,
  compaction with repacking), `zx_dedup.dart` (zpaq's content-defined
  fragmenter, the chunk index, the solid and dedup features of a set of
  extents), `zx_chunkrun.dart` (the chunk runs: the on-disk index of the
  chunks sorted by SHA-256, its writer, its lookups by random access, the
  merge of runs), `zx_memory.dart` (the memory estimates and the worker count),
  `zx_handler.dart` (the 7-Zip shaped handler: properties, extraction,
  random access, updates, timeline, the sequential reader of pipes).
  `lib/src/cli/arc_zx.dart` adapts it; `update.dart` lets it write in
  place (`ZxArc.updateFile`) instead of the temporary file and rename of
  7-Zip, and gives it the `-v` sizes instead of `MultiOutStream`.
- **Appends in place.** An update of a .zx file opens it in append mode,
  truncates what follows the last valid Footer (an interrupted update) and
  writes a generation; nothing before is changed, so a crash leaves the
  previous state readable. dart:io opens files with FILE_SHARE_READ and
  FILE_SHARE_WRITE on Windows, so the handle that reads the archive (the
  CLI's, the worker's) does not block the append. When the file can not be
  opened for appending (another program holds it without sharing
  writing), the handler writes `name.zx-part` (the bytes up to the last
  valid Footer, then the generation: the same bytes), closes the reader
  and the caller's handle (`releaseInput`: Windows does not rename over a
  file open without sharing deletion) and renames it over the archive,
  trying again for about 3 seconds; a lasting lock leaves the archive as
  it was. `zxOpenForAppend` and `zxReplaceFile` are the seams the tests use
  to simulate a locked file. A volume set gets new volume files after the
  last one. The CLI skips 7-Zip's temporary file and its "the file
  already exists" check for .zx (`zxInPlace` in `update.dart`), and
  `zx_worker.dart` does the same for `ZxArchive`. A new archive is still
  written as `name.zx-part` by `ZxArchive` and renamed at the end.
  Compaction writes `name.zx-compact` and renames it over the archive.
- **Detection.** The magic at offset 0 (a signature); the Split handler
  refuses a file that starts with it, so `x.zx.001` opens as .zx, and
  `update.dart` turns the Split type of such a name into zx.
- **Hot loops.** TLSH (`Tlsh.update`) keeps its window and checksum in
  locals and the buckets in a `Uint32List`; CRC-32C is slicing-by-8 like
  `crc.dart`; the per file SHA-256 and TLSH run on the handler's isolate
  while the workers code the blocks.
- **Dedup.** The writer cuts each file with zpaq's fragmenter (64 KiB on
  average), hashes each chunk with SHA-256 and looks it up in
  `ZxChunkIndex` (the chunks stored in this generation: open addressing
  on the first bytes of the hash, about 100 bytes per chunk on the
  handler's isolate), then in the chunk runs of the last Index (record
  0x36, checked against the block table by its fingerprint): a run keeps
  its fences and Bloom filter in memory (1.5 bytes per chunk) and reads
  one 3 KiB page for a lookup the filter lets through. A new chunk goes to
  the dedup chunk store block being filled, a known one becomes an
  extent. At the end of the generation the chunks in memory are sorted
  and written as a run, merged (a streamed k-way merge, counted then
  written) with the last runs of about their size. A chunk table of zx
  0.5.0 (record 0x34) is loaded into `ZxChunkIndex` once and goes into the
  run. A file with the size and SHA-256 of a stored file reuses its
  extents: the SHA-256 is computed while the file is chunked, and the new
  chunks of a file whose size matches wait in a spill file in the system's
  temporary folder, so no file is held whole. New data is placed as
  positions in the stream of new data and turned into extents when the
  blocks are written, so the output does not depend on the number of
  workers. Compaction repacks partly used blocks in the workers (decode,
  then code again with the rebuilt chain; zpaq keeps its method, stored
  in its props; a zpaq block of zx 0.5.0 without it is copied whole) and
  writes the chunks still used as runs for the last kept generation.
- **Pipes.** `openSeq` copies the input (in memory up to 16 MiB, else to a
  temporary folder, `-mpipetemp`) and opens it as a file, because an
  appended archive tells what a generation deleted or replaced only in
  its Index, after the data (docs/zx-format.md, section 8.1): the items
  are the state of the last generation or of `-mversion`. `-mpipe=onepass`
  reads a streamed file in one pass without a copy: every version in
  stream order, with a warning when later generations replaced or deleted
  some. `ZxSeqReader` numbers generations by their Footers, decodes the
  Index blocks it meets and gives `currentEntries` after a whole pass (the
  reader of a streamed file whose Footers are all damaged uses it: the last
  version of each path).
- **Volumes until full.** `-mvdir=DIR:full` asks `df` (PowerShell on
  Windows) for the free space; without an answer the volume sink reserves
  the volume's space by writing zeros up to 96 MiB ahead of the data and
  ends the volume where a write fails (the zeros left are cut off at
  close). `zxFreeSpaceTool` and `zxPreallocWrite` are the seams of the
  tests.
- **Limits.** The chunks a generation stores are in memory until its end
  (about 100 bytes each: 1.6 GB for a single update of 1 TB of new data
  at 64 KiB chunks); the runs of earlier generations cost 1.5 bytes a
  chunk. Merged runs stay in the file until a compaction and are not
  counted in `Wasted`. Reading a pipe needs room for a copy of it (the
  one pass reader does not, but gives every version). The fallback of a
  locked archive and the Windows sharing rules are simulated in the tests,
  not run on Windows.
