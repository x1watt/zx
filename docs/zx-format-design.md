# The .zx format (design proposal, draft 0)

Status: proposal for review. Nothing here is implemented yet.

## 1. Goals

1. **One extension, any algorithm.** A `.zx` file is a container: each part
   of it says which codec chain encoded it (LZMA2, zstd, PPMd, zpaq CM,
   Deflate, BZip2, store, filters such as BCJ or Delta...). The file
   extension and the magic bytes say only "zx can decode this", never which
   algorithm is inside, so new algorithms can be added without a new
   extension.
2. **Compatibility is explicit.** Every file states the minimum zx version
   able to decode it and the features it needs. An older zx refuses cleanly
   with a precise message ("needs zx 0.7.0 or later: codec zstd-long")
   before reading any data, instead of failing half way.
3. **Forward extensible.** Unknown optional parts are skipped by old
   readers; unknown required parts make them refuse. No guessing.
4. **Single files and archives.** The same format holds one compressed
   stream (like `.xz`, `.gz`) or many files with metadata (like `.7z`,
   `.tar.xz`), including links, modes, owners and nanosecond times.
5. **Streamable and random access.** Writable to a pipe (`zx a -so`),
   readable from a pipe in order, and, when seekable, listable and
   extractable per file without decoding everything.
6. **Fast in parallel.** Data is cut into independent blocks so that
   compression and decompression use all cores (isolates), and a damaged
   block loses only that block.
7. **Safe.** Every structure is checksummed; optional authenticated
   encryption of data and of names.

## 2. Versioning model (the key part)

Three separate numbers, all in the header:

| Field | Meaning | Who sets it |
|---|---|---|
| `format_version` (u16) | Version of this container layout. Bumped only for a change old readers cannot parse at all (expected to stay 1 for a long time). | The spec |
| `min_reader_version` (major.minor.patch, 3 x u16) | The oldest zx release that can decode everything in this file. Computed by the writer as the maximum of the "introduced in" versions of every codec, filter, record type and feature it actually used. | The writer, automatically |
| `writer_version` (3 x u16) + writer name | Which program wrote it ("zx 0.9.2 (Dart)"), for diagnostics only. | The writer |

Plus two feature bit sets, as in ext4 (compat / incompat):

- `required_features` (u64): each bit is a feature a reader must implement
  to decode the file (for example: solid blocks, encryption, dedup
  chunks, recovery record interleaving). An unknown set bit means "refuse".
- `optional_features` (u64): features a reader may ignore and still decode
  correctly (for example: an index of per-file hashes, a thumbnail, a
  recovery record at the end). Unknown bits are ignored.

Reader decision, before touching any data:

1. Magic wrong: not a zx file.
2. `format_version` newer than the reader knows: refuse, "format version N
   is newer than this zx (supports up to M), upgrade zx".
3. `min_reader_version` newer than the reader: refuse with that version.
4. Any unknown bit in `required_features`: refuse, naming the bit.
5. Otherwise read; while reading, an unknown codec id or an unknown
   critical record (section 4) is still a hard error (defence in depth, for
   files written by other implementations that set the header wrong).

Why both a version and feature bits: the version gives users a simple
message ("install zx 0.7+"); the bits let other implementations (a C or
Rust reader later) declare exactly what they support without having to
match zx's release numbering.

A **codec registry** document (`docs/zx-codecs.md`) lists every codec and
filter id with: name, parameters layout, the zx version that introduced it,
and a reference to its specification. Ids are never reused.

## 3. File layout

All integers little endian. `vint` = unsigned LEB128 (1 to 10 bytes), used
wherever a value can grow. All strings UTF-8, length prefixed, no NUL.

```
File   = Header, Block*, Index, Footer
```

### 3.1 Header (fixed 64 bytes, then optional header records)

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `89 5A 58 0D 0A 1A 0A 00` (see below) |
| 8 | 2 | format_version (1) |
| 10 | 6 | min_reader_version: major, minor, patch (u16 each) |
| 16 | 6 | writer_version (u16 x 3) |
| 22 | 2 | header_flags (streamed / seekable index present / encrypted headers / multi-volume) |
| 24 | 8 | required_features |
| 32 | 8 | optional_features |
| 40 | 16 | archive id (random 128 bits; ties volumes and appended updates together) |
| 56 | 4 | length of the header records that follow (0 if none) |
| 60 | 4 | CRC-32C of bytes 0..59 plus the header records |

Magic in the style of PNG: the first byte `0x89` is non-ASCII (detects 7-bit
transfers and keeps text tools from treating it as text), `ZX` is readable
in hex dumps, `0D 0A` and `1A` detect line-ending conversion and DOS EOF
truncation, the final `00` keeps it from being a C string. Registered as a
zx signature at offset 0; MIME type `application/x-zx`.

Header records (TLV, section 4) carry things like the writer name string,
the KDF parameters when encrypted, the volume number, the creation time.

### 3.2 Blocks

The unit of coding and of parallelism:

```
Block = BlockHeader, payload
BlockHeader = marker "ZXB" 0x01,
              vint header_size, vint block_type,
              vint coder_chain_id, vint unpacked_size, vint packed_size,
              check_type (u8), check (0/4/8/32 bytes of the unpacked data),
              CRC-32C of the block header
```

- `block_type`: file data, solid data (several files concatenated),
  metadata (a compressed index part), dedup chunk store.
- `coder_chain_id` refers to a coder chain declared in the index or,
  in streamed mode, in an inline "coder chain" record just before the
  first block that uses it.
- Default block size around 8 to 64 MiB (codec dependent), so N blocks
  decode on N isolates. Solid groups are split into blocks too.
- `check`: xxHash64 by default (fast, already in the repo); CRC-32C,
  SHA-256 and BLAKE2sp selectable. The block header has its own CRC so a
  corrupt size cannot send the reader far away.
- A reader can resynchronise after damage by scanning for the next block
  marker and validating its header CRC.

### 3.3 Coder chains

A coder chain is an ordered list of coders, applied on write from first to
last and undone in reverse:

```
CoderChain = vint chain_id, vint coder_count,
             coder_count x ( vint codec_id, vint props_size, props )
```

Example: `[BCJ-x86] [LZMA2 dict=64M]`, `[Delta 4] [zstd level 19, long 27]`,
`[PPMd8 order 8]`, `[zpaq-cm method 5]`, `[store]`.

Codec ids: a zx-owned id space (vint). Where 7-Zip already assigned a
method id, the registry records it for reference, but zx ids are compact
small numbers (store 0, LZMA2 1, zstd 2, ...). Parameters are codec
specific bytes defined in the registry. Every codec entry has an
"introduced in" zx version that feeds `min_reader_version`.

The writer may choose the chain per file or per block (the "auto" method:
detect executables and apply BCJ, detect already-compressed data and
store it, pick PPMd for text when it wins; see section 7).

### 3.4 Index (the central directory)

Written after the blocks as one or more metadata blocks (so it is
compressed and checksummed like data, and encrypted when names are
encrypted). Content, as TLV records:

- coder chain table;
- block table: offset, sizes, chain, check (enables random access
  without scanning);
- entries: one record per item:
  - path (UTF-8, `/` separated, relative, no `..`),
  - type: file, directory, symlink (target), hardlink (entry ref),
    char/block device (major, minor), fifo, socket,
  - size, mode (POSIX), uid/gid and user/group names, attributes
    (Windows), times as nanoseconds since the Unix epoch (mtime required,
    atime, ctime, birth time optional),
  - data location: list of (block, offset in block, length) extents,
    allowing solid data and dedup;
  - optional: per-file hash, xattrs, ACLs, sparse map, comment;
- archive comment, total sizes.

### 3.5 Footer (fixed 32 bytes at the end)

| Size | Field |
|---|---|
| 8 | index offset |
| 8 | index total size |
| 4 | number of blocks |
| 4 | footer flags |
| 4 | CRC-32C of the footer's first 24 bytes |
| 4 | magic `ZXE\x1A` |

A seekable reader opens by reading the header (compatibility check) and
the footer (index), then only the blocks it needs. A missing or corrupt
footer is recovered by scanning blocks from the start (the index can also
be rebuilt from inline records in streamed files).

## 4. Records: how the format stays extensible

Every variable structure (header records, index entries, entry
attributes) is a list of TLV records:

```
Record = vint type, vint length, payload
```

Bit 0 of `type` is the **critical** flag. A reader that meets an unknown
record type skips it using `length` when the flag is clear, and refuses
with "unsupported record type N (critical)" when it is set. New optional
metadata (for example macOS resource forks, file capabilities) is added as
non-critical records and never breaks old readers; a record that changes
how data must be decoded is critical and also raises
`min_reader_version`.

## 5. Streamed (pipe) mode

When the output is not seekable, each file's entry is also written inline
as a record just before its data blocks, and the index is still written at
the end. A reader on a pipe decodes in order from the inline records; a
seekable reader uses the index. Flag `streamed` in the header tells which
is guaranteed.

## 6. Encryption

- Optional, feature bit `encryption` (required feature).
- Key derivation: scrypt (already implemented in the vendored zpaq code)
  with parameters and salt in a header record; Argon2id can be added
  later as another KDF id.
- Data: AES-256 in CTR mode with a per-block nonce, authenticated with
  HMAC-SHA-256 over header and ciphertext (encrypt-then-MAC), using
  primitives the repo already has. AES-GCM or ChaCha20-Poly1305 can be
  registered later as other cipher ids.
- `encrypted headers` flag: the index and inline entry records are in
  encrypted metadata blocks, so names and sizes are hidden; only the fixed
  header and footer are clear.
- A password check value lets zx report "wrong password" immediately.

## 7. Compression policy of the zx writer (not part of the format)

The format allows any chain; the writer's defaults decide what users get:

- `-mx` levels map to chains, for example: 1 zstd fast, 3 zstd, 5 LZMA2
  (default), 7 LZMA2 large dictionary, 9 LZMA2 or zpaq CM on text-heavy
  input.
- Content analysis per file: executables get BCJ/ARM64 filters, audio and
  images Delta, already compressed data (jpg, mp4, zip, 7z...) is stored,
  text may go to PPMd when it compresses better.
- Solid groups by extension (as 7-Zip does) with a size cap per group, so
  single-file extraction stays fast.
- Optional deduplication (content-defined chunks, as in zpaq) behind a
  required feature bit.

## 8. Other features to keep room for (optional, later)

- Appending updates without rewriting (new blocks plus a new index and
  footer at the end; the previous index stays for history, like zpaq
  versions). Feature bit `appendable`.
- Multi-volume (`x.zx.001`...) tied by archive id and volume number.
- Recovery record (Reed-Solomon, as already implemented for RAR5) as an
  optional trailing structure.
- A nested-archive hint record, so the app can show that an item is
  itself an archive without sniffing.

## 9. What zx must implement (when approved)

1. `lib/src/format/zx/`: reader and writer (seekable and streamed),
   registered as format `zx`, extension `.zx`, signature at offset 0, with
   update support (rewrite first; append later).
2. `docs/zx-format.md` (the normative spec, from this draft) and
   `docs/zx-codecs.md` (registry with "introduced in" versions).
3. A `ZxCodecRegistry` in code: id, name, props parser, "introduced in",
   encoder and decoder factories; `min_reader_version` computed from it.
4. Parallel block coding in isolates (the first format of the project
   designed for it from the start).
5. Tests: round trips per codec and chain, compatibility refusal tests
   (a file claiming a newer `min_reader_version`, an unknown required
   feature bit, an unknown critical record, an unknown codec id), streamed
   vs seekable, damaged block recovery, encryption with wrong password,
   fuzzing of headers.
6. App: `.zx` in New archive (default format?), MIME type
   `application/x-zx` registered through the integration, icon.

## 10. Decisions (owner, 2026-09-27)

1. Default codec chain: decided after benchmarking modern high-ratio
   codecs (cmix, paq8 and others) against LZMA2/zstd; the spec leaves it
   open and reserves an experimental codec id range.
2. `.zx` becomes the app's default format for new archives.
3. Updates are append-only with generations (history), plus a compact
   operation that rewrites the file keeping only live data. Every
   generation carries its UTC time, so versions can be listed and selected
   by date (`YYYY-MM-DD`), and each file has a timeline of its versions.
4. Every file carries its SHA-256 (with a sorted lookup table for fast
   search) and a TLSH digest (approximate/similarity search). Block
   integrity checks stay separate and selectable.

The normative specification is `docs/zx-format.md`.
