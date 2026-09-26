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
- `lib/src/crypto`: `aes.dart` (Aes.c, CBC), `sha256.dart`,
  `seven_zip_aes.dart` (7zAes.cpp: key derivation, properties, coder).
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
- `lib/src/cli`, `bin/7z.dart`: the command line tool, 7zr's commands and
  switches (ArchiveCommandLine.cpp, Main.cpp, List, Extract, Update...).
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
  `-snl`. POSIX modes are stored in the high attribute bits as 7-Zip does;
  on extraction modification times are restored, modes are not (dart:io
  has no chmod).

## 8. Known limits

- Formats and methods of the full 7-Zip that the SDK does not contain:
  zip, rar, gzip, bzip2, tar, cab, iso, wim and the others; Deflate,
  Deflate64, BZip2, ZSTD methods inside 7z. Archives using them open and
  list, and those items fail with `unsupportedMethod`.
- SFX modules, multi-volume creation from the API (the writer supports
  `MultiOutStream`, the CLI exposes `-v`), NTFS alternate streams and
  security descriptors.
- The web platform: archives are files.
