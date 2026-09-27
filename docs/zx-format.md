# The .zx archive format, version 1 (draft specification)

Status: draft for review. The default codec chain is intentionally not
fixed by this document; it will be chosen after benchmarking (section 12).
The design rationale is in `docs/zx-format-design.md`.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Conventions

- Byte order: little endian for all fixed-size integers.
- `u8`, `u16`, `u32`, `u64`: unsigned integers of that many bits.
- `vint`: unsigned LEB128. 7 bits per byte, low bits first, high bit set
  on every byte except the last. At most 10 bytes. A reader MUST reject a
  vint longer than 10 bytes or one whose value does not fit in 64 bits.
  Writers MUST use the shortest encoding.
- `string`: `vint length` then that many bytes of UTF-8, no terminating
  NUL. Readers MUST reject invalid UTF-8 in paths.
- `bytes(n)`: n raw bytes.
- `version`: three `u16`: major, minor, patch. Versions compare
  lexicographically.
- CRC-32C: the Castagnoli CRC (polynomial 0x1EDC6F41 reflected,
  0x82F63B78), initial value 0xFFFFFFFF, final xor 0xFFFFFFFF.
- Offsets are absolute byte offsets from the start of the file. In
  multi-volume sets, block locations are a volume number plus an offset
  in that volume, and Footer offsets refer to the last volume (section
  10).

## 2. Overall structure

```
ZxFile = Header, { Block }, Index, Footer
```

A file MUST start with a Header and end with a Footer. Blocks carry data
and metadata. The Index is stored in one or more metadata blocks and
located by the Footer. With the `appendable` feature (section 9) a file may
contain several Index and Footer pairs; the last Footer is the current one.

## 3. Header

Fixed part, 64 bytes:

| Offset | Type | Field |
|---|---|---|
| 0 | bytes(8) | magic: `89 5A 58 0D 0A 1A 0A 00` |
| 8 | u16 | format_version: 1 |
| 10 | version | min_reader_version |
| 16 | version | writer_version |
| 22 | u16 | header_flags |
| 24 | u64 | required_features |
| 32 | u64 | optional_features |
| 40 | bytes(16) | archive_id (random) |
| 56 | u32 | records_size: size of the header records that follow |
| 60 | u32 | header_crc: CRC-32C of bytes 0..59 and of the header records |

Followed by `records_size` bytes of header records (section 5).

`header_flags`:

| Bit | Name | Meaning |
|---|---|---|
| 0 | streamed | Entry records are also written inline before their data (section 8). |
| 1 | encrypted_metadata | The Index and inline entry records are encrypted (section 7). |
| 2 | multi_volume | The file is one volume of a set (section 10). |
| 3..15 | | Reserved, MUST be 0 when writing, MUST be ignored when reading. |

### 3.1 Compatibility check

Before reading anything after the header, a reader MUST:

1. Check the magic; otherwise the file is not a zx file.
2. Check `header_crc`; on mismatch report a damaged header.
3. If `format_version` is greater than the highest it supports: refuse,
   reporting both numbers.
4. If `min_reader_version` is greater than its own version: refuse,
   reporting `min_reader_version`.
5. If `required_features` has any bit it does not implement: refuse,
   naming the bits.

Unknown bits in `optional_features` MUST be ignored.

A writer MUST set `min_reader_version` to the greatest "introduced in"
version (section 11) among: the format version itself, every codec and
filter used, every critical record type used, every required feature set.
It MUST set in `required_features` exactly the required features it uses.

### 3.2 Feature bits

`required_features`:

| Bit | Name | Section |
|---|---|---|
| 0 | solid | Blocks holding data of several entries. |
| 1 | encryption | Section 7. |
| 2 | dedup | Entries share data chunks (section 6.4). |
| 3 | appendable | Several Index/Footer generations (section 9). |
| 4 | multi_volume | Section 10. |
| 5..63 | | Reserved for future versions. |

`optional_features`:

| Bit | Name | Meaning |
|---|---|---|
| 0 | hash_table | The Index contains the SHA-256 lookup table (section 6.5). |
| 1 | similarity | Entries carry TLSH digests (section 6.3). |
| 2 | recovery | A recovery record follows the last Footer. |
| 3..63 | | Reserved. |

## 4. Blocks

```
Block = BlockHeader, payload
BlockHeader =
  bytes(4)  marker: "ZXB" 0x01
  vint      header_size   (size of the fields from block_type to check,
                           inclusive, so unknown trailing fields can be
                           skipped by later versions)
  vint      block_type
  vint      chain_id      (section 4.2)
  vint      unpacked_size
  vint      packed_size   (size of payload)
  u8        check_type
  bytes(n)  check         (n from check_type)
  u32       header_crc    (CRC-32C of marker through check)
```

`block_type`: 0 data, 1 solid data, 2 metadata (Index or inline records),
3 dedup chunk store, 4 padding (payload ignored). Unknown block types MUST
be treated as an error unless the block lies outside every extent the
Index references (then it MAY be skipped).

`check_type` and the check of the unpacked payload:

| Value | Check | n |
|---|---|---|
| 0 | none | 0 |
| 1 | CRC-32C | 4 |
| 2 | xxHash64 | 8 |
| 3 | SHA-256 | 32 |
| 4 | BLAKE2sp | 32 |

Block checks protect integrity; they are independent of the per-entry
SHA-256 (section 6.2), which identifies content.

Writers SHOULD keep `unpacked_size` of data blocks between 1 MiB and
64 MiB so that blocks can be coded in parallel; readers MUST accept any
size up to 2^40 and MAY refuse larger blocks.

### 4.1 Resynchronisation

A reader facing damage MAY scan forward for the marker `ZXB\x01` and accept
a block when its `header_crc` is valid.

### 4.2 Coder chains

A chain is declared once and referenced by id:

```
Chain = vint chain_id, vint coder_count,
        coder_count x Coder
Coder = vint codec_id, vint props_size, bytes(props_size)
```

On writing, coders apply in order (for example a BCJ filter, then a
compressor, then encryption is applied to the result, section 7). On
reading they are undone in reverse order. Chain id 0 is reserved for
"store" (no coders) and is always defined.

Chains are declared in the Index (record 0x10) and, in streamed files, in
an inline metadata block before the first block using them.

`codec_id` values are assigned in the codec registry (section 11). An
unknown `codec_id` MUST make the reader refuse the block with an
"unsupported codec" error naming the id.

## 5. Records

All variable structures (header records, Index content, entry
attributes) are sequences of records:

```
Record = vint type, vint length, bytes(length)
```

Bit 0 of `type` is the critical flag. A reader that does not know a
record type:
- MUST skip it when the critical flag is 0;
- MUST refuse the file (or the entry, if the record is inside an entry)
  when the critical flag is 1.

Record types are listed with their critical flag already included in the
value (odd values are critical).

### 5.1 Header records

| Type | Crit | Content |
|---|---|---|
| 0x02 | no | writer name: string (for example "zx 0.9.2 (Dart)") |
| 0x04 | no | creation time: vint nanoseconds since 1970-01-01 UTC |
| 0x05 | yes | KDF parameters (section 7) |
| 0x07 | yes | volume: vint volume number (0 based), vint volume count or 0 if unknown |
| 0x08 | no | archive comment: string |

## 6. Index

The Index is the payload of one or more metadata blocks (block_type 2).
Its location is given by the Footer. Its unpacked content is a sequence
of records:

| Type | Crit | Content |
|---|---|---|
| 0x10 | no | chain declaration: Chain (section 4.2) |
| 0x12 | no | block table (section 6.1) |
| 0x21 | yes | entry (section 6.2); one per item, in listing order |
| 0x30 | no | SHA-256 lookup table (section 6.5) |
| 0x32 | no | TLSH lookup list (section 6.5) |
| 0x40 | no | previous Index location (section 9.1) |
| 0x42 | no | generation number, time and comment (section 9.1) |

Chain declarations and the block table MUST appear before the first entry.

### 6.1 Block table

```
BlockTable = vint block_count,
             block_count x ( vint offset, vint header_size_total,
                             vint packed_size, vint unpacked_size,
                             vint chain_id )
```

`offset` is the position of the block marker. It lets a reader seek to
any block without scanning. Block numbers used by entries are indexes in
this table.

### 6.2 Entry

An entry record's payload is itself a sequence of attribute records:

| Type | Crit | Content |
|---|---|---|
| 0x51 | yes | path: string, `/` separated, relative, no empty, `.` or `..` component |
| 0x53 | yes | kind: vint (0 file, 1 directory, 2 symlink, 3 hard link, 4 char device, 5 block device, 6 fifo, 7 socket) |
| 0x55 | yes | size: vint (bytes of content) |
| 0x57 | yes | extents: vint count, count x ( vint block, vint offset_in_block, vint length ) |
| 0x59 | yes | link target: string (symlink target, or the path of the hard link's first entry) |
| 0x5B | yes | device: vint major, vint minor |
| 0x5C | no | posix mode: vint (permission and special bits, without the type) |
| 0x5E | no | owner: vint uid, vint gid, string user, string group |
| 0x60 | no | windows attributes: vint |
| 0x62 | no | mtime: vint nanoseconds since 1970-01-01 UTC (a signed value is zigzag encoded) |
| 0x64 | no | atime (as mtime) |
| 0x66 | no | ctime (as mtime) |
| 0x68 | no | birth time (as mtime) |
| 0x6A | no | SHA-256: bytes(32) of the entry content |
| 0x6C | no | TLSH: string, the TLSH digest text (section 6.3) |
| 0x6E | no | xattr: string name, vint length, bytes value (repeatable) |
| 0x70 | no | comment: string |
| 0x72 | no | sparse: vint count, count x ( vint offset, vint length ) data ranges; the rest reads as zeros |
| 0x74 | no | nested archive hint: string format name (the content is itself an archive) |
| 0x76 | no | since generation: vint (section 9.1.1) |

Rules:
- `path`, `kind` MUST be present. `size` and `extents` MUST be present for
  files (an empty file has size 0 and no extents).
- The content of a file is the concatenation of its extents in order. The
  sum of extent lengths MUST equal `size` (or, with `sparse`, the sum of
  the data ranges).
- Writers SHOULD always write SHA-256 for files (it is required by the
  `hash_table` optional feature). Readers that extract a file with a
  SHA-256 MUST verify it and report a mismatch as a data error.

### 6.3 TLSH

TLSH (Trend Micro Locality Sensitive Hash) digests allow finding similar
files. The digest is stored as its standard text form (for example
`T1` followed by 70 hex digits). Files smaller than the minimum TLSH input
(50 bytes) or with too little variation have no digest. The TLSH variant
(buckets, checksum length) is the one given by its text form.

### 6.4 Dedup

With the `dedup` required feature, identical chunks are stored once (in
data or dedup chunk store blocks) and several entries' extents point to
them. The chunking algorithm is a writer choice and is not part of the
format.

### 6.5 Lookup tables

For fast search without reading every entry:

```
Sha256Table = vint count,
              count x ( bytes(32) sha256, vint entry_number )
              sorted by sha256 ascending (binary search)
TlshList    = vint count, count x ( string tlsh, vint entry_number )
```

`entry_number` is the position of the entry in the Index (0 based).

## 7. Encryption

Feature bit `encryption`. Parameters in header record 0x05:

```
Kdf = vint kdf_id, vint params_size, bytes(params_size)
      vint cipher_id,
      bytes(16) password_check
```

- `kdf_id` 1: scrypt, params `vint log2_N, vint r, vint p, bytes(32) salt`.
- `cipher_id` 1: AES-256-CTR with HMAC-SHA-256 (encrypt then MAC).
  The KDF output is 64 bytes: 32 for AES, 32 for HMAC.
- Each encrypted block payload is `bytes(16) nonce, ciphertext,
  bytes(32) mac`, where the MAC covers the block header fields before the
  CRC, the nonce and the ciphertext. `packed_size` includes nonce and MAC.
- `password_check`: first 16 bytes of HMAC-SHA-256(key_mac, "zx password
  check"), letting a reader reject a wrong password before decoding.
- Without `encrypted_metadata`, only data blocks are encrypted. With it,
  metadata blocks (Index, inline records) are encrypted too, so names and
  sizes are hidden.

Other KDFs (for example Argon2id) and ciphers are added as new ids with
their "introduced in" versions.

## 8. Streamed files

Header flag `streamed`: every entry is also written as an inline metadata
block (block_type 2) containing its entry record (and any new chain
declaration) immediately before its data blocks. A reader on a
non-seekable input decodes entries in order from these inline records.
The Index and Footer are still written at the end.

## 9. Appendable files and compaction

Required feature `appendable`. This is the normal update mode of zx for
`.zx` archives: an update never rewrites existing bytes.

### 9.1 Generations

Each update creates a new generation, numbered from 1 (the initial
creation). An update:

1. Truncates nothing and changes no earlier byte.
2. Appends the blocks holding new or changed data.
3. Appends a new Index describing the complete current state. Unchanged
   entries point to blocks of earlier generations; deleted entries are
   simply absent.
4. Appends a new Footer. The last valid Footer is the current state.

The Index of every generation contains a generation record:

| Type | Crit | Content |
|---|---|---|
| 0x40 | no | previous Index: vint offset, vint size (absent in generation 1) |
| 0x42 | no | generation: vint number, vint time (ns since epoch), string comment |

Following the 0x40 records from the last Index gives every earlier state:
a reader MAY list or extract the archive as of any generation.

Every Index MUST contain the 0x42 generation record, and its time MUST be
the UTC time at which the update was written (nanoseconds since
1970-01-01T00:00:00Z). Generation times are non-decreasing; a writer whose
clock is behind the previous generation MUST store the previous time
instead.

### 9.1.1 Timelines (informative, how zx uses the times)

- Listing generations shows number, date and comment, dates in ISO 8601
  (`YYYY-MM-DD`, or `YYYY-MM-DD HH:MM:SS` when asked), converted to local
  time for display.
- A generation can be selected by number or by date: a date `D` (or date
  and time) selects the last generation whose time is not after the end of
  `D` in local time. Example: "the archive as of 2026-09-01".
- File timeline: for one path, zx walks the generations and reports each
  distinct version of that file (different SHA-256) with the date of the
  generation that introduced it, and the generation where it was deleted,
  if any. Entry attribute 0x76 makes this cheap.

Entry attribute for timelines:

| Type | Crit | Content |
|---|---|---|
| 0x76 | no | since generation: vint, the generation that wrote this content of the entry (unchanged entries carry the value forward) |

Crash safety: an update interrupted before its Footer is complete leaves a
trailing partial generation. A reader MUST use the last Footer whose
`footer_crc` is valid and whose Index decodes; bytes after it are ignored,
and the next update SHOULD overwrite them (the one case where existing
bytes are replaced: garbage after the last valid Footer).

### 9.2 Compaction

Data of deleted or replaced entries stays in the file until the archive is
compacted. Compaction is an operation of the writer, not a structure:

- It writes a new file (then atomically renames it over the old one)
  holding only the blocks referenced by the current generation (or, with
  a "keep last N generations" option, by the last N generations), with a
  new block table, fresh Indexes and Footer.
- Blocks are copied as they are, without recompression, when all of their
  content is still referenced. Blocks that are only partly referenced
  (solid or dedup blocks) MAY be repacked; the writer chooses.
- The compacted file keeps the archive_id and restarts the generation
  history at the kept generations (their numbers and times are preserved).
- Writers SHOULD report how much space compaction would free (the sum of
  unreferenced block bytes) so tools can suggest it, and MAY compact
  automatically when the wasted fraction exceeds a user setting.

## 10. Multi-volume sets

Required feature `multi_volume`. Used when an archive must be split into
files of a given size, for example to spread it over several disks.

### 10.1 Volumes

- Volumes are named `name.zx.001`, `name.zx.002`, ... (three digits, more
  when needed). The first volume may also be named `name.zx`.
- Each volume is a complete, self-identifying file: it starts with a
  Header carrying the set's `archive_id` and a volume record 0x07 with its
  number, and ends with a volume trailer (section 10.3). A reader can
  therefore tell which archive and which position a file belongs to, even
  after files were renamed or moved.
- A block MUST lie entirely inside one volume. The writer starts a new
  volume when the next block does not fit. Blocks larger than a volume
  are written with a smaller block size, never split. (This keeps every
  volume independently readable, and a missing volume only affects the
  entries whose extents use it.)
- Volume sizes need not be equal: each volume has its own size limit
  (section 10.4).

With the multi_volume feature, block locations are (volume, offset):

```
BlockTable (multi-volume) = vint block_count,
    block_count x ( vint volume, vint offset_in_volume,
                    vint header_size_total, vint packed_size,
                    vint unpacked_size, vint chain_id )
```

### 10.2 Volume table

The Index (held in the last volume, written last) contains a volume table
so a reader knows every volume before opening them:

| Type | Crit | Content |
|---|---|---|
| 0x45 | yes | volume table: vint count, count x ( vint number, string file name, vint size, bytes(8) xxHash64 of the whole volume file ) |

### 10.3 Volume trailer

Every volume except the last ends with a 32-byte trailer in place of the
Footer:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | volume number |
| 4 | u32 | reserved (0) |
| 8 | u64 | data size of this volume (header included) |
| 16 | bytes(8) | first 8 bytes of archive_id |
| 24 | u32 | CRC-32C of bytes 0..23 |
| 28 | bytes(4) | magic `ZXV` 0x1A |

The last volume ends with the normal Footer (section 14), whose offsets
refer to that volume.

### 10.4 Writing (informative, zx options)

- A volume size, or a list of sizes, one per volume, the last one
  repeating (for example "first 4 GiB, then 25 GiB each").
- A list of destination directories, each optionally with a size budget
  or "until the disk is full" (free space checked before each volume):
  volumes are written to the first directory until its budget is used,
  then to the next. Example: volumes 1 to 3 on `/mnt/disk1`, the rest on
  `/mnt/disk2`.
- Appending a generation to a multi-volume archive never rewrites earlier
  volumes: the new blocks, Index and Footer go into new volumes after the
  last one, whose Footer is replaced by a volume trailer. Old volumes can
  stay on read-only or offline disks.
- Compaction rewrites the whole set, with the same options.

### 10.5 Reading (informative, zx options)

- A list of search directories where volumes may be found, in addition to
  the directory of the file that was opened (for example one directory
  per disk). Volumes are identified by their Header (`archive_id` and
  volume number), so their file names and locations do not matter.
- Only the volumes holding the requested blocks are opened: listing needs
  only the last volume; extracting one file needs only the volumes of its
  extents.
- A missing volume is reported by number and expected name (from the
  volume table); entries that do not use it are still extracted.

## 11. Codec registry

Each codec and filter has: `codec_id`, name, props layout, the zx version
that introduced it ("introduced in"), and the specification it follows.
Ids are never reused or redefined. Ranges:

| Range | Use |
|---|---|
| 0 to 0x3FF | Standard codecs and filters (stable) |
| 0x400 to 0x7FF | Encryption and integrity transforms |
| 0x10000 to 0x1FFFF | Experimental codecs (benchmarks). Files using them MUST set `min_reader_version` to the exact zx version that wrote them, and zx MUST warn when creating them. |
| other | Reserved |

Initial standard entries (introduced in zx 0.5.0, props as in section 13):

| Id | Name | Props |
|---|---|---|
| 0 | store | none |
| 1 | LZMA2 | 1 byte dictionary size code (as 7z) |
| 2 | LZMA | 5 bytes (as 7z) |
| 3 | zstd | vint window_log |
| 4 | PPMd7 (var.H) | 5 bytes (as 7z) |
| 5 | PPMd8 (var.I) | order, mem, restore method |
| 6 | BZip2 | none |
| 7 | Deflate | none |
| 8 | zpaq | the zpaq block header (config) is inside the payload |
| 9 | LZ4 | none |
| 10 | LZO1X | none |
| 0x40 | BCJ x86 | optional u32 start offset |
| 0x41 | ARM | as 0x40 |
| 0x42 | ARMT | as 0x40 |
| 0x43 | ARM64 | as 0x40 |
| 0x44 | PPC | as 0x40 |
| 0x45 | SPARC | as 0x40 |
| 0x46 | IA64 | as 0x40 |
| 0x47 | RISCV | as 0x40 |
| 0x48 | Delta | 1 byte distance - 1 |

Experimental candidates for benchmarking (ids in 0x10000+, to be assigned
when implemented): cmix, paq8 variants, NNCP-style neural compressors, and
other high-ratio context-mixing models.

## 12. Default codec selection

Not part of the format. The zx writer's defaults (which chain for which
content and level) will be decided after benchmarking the candidates on
representative data (text, source code, binaries, firmware, media), and
documented separately.

## 13. Reading algorithm (informative)

1. Read the Header, run the compatibility check (3.1).
2. Seekable: read the Footer, read the Index blocks, decode records;
   non-seekable with `streamed`: read blocks in order, use inline records.
3. For each entry to extract: for each extent, decode (or reuse from a
   cache) its block, copy the range; verify the block check and, at the
   end, the entry SHA-256.

## 14. Footer

Last 32 bytes of the file (of the last volume):

| Offset | Type | Field |
|---|---|---|
| 0 | u64 | index_offset (marker of the first Index block) |
| 8 | u64 | index_size (bytes from index_offset to the footer) |
| 16 | u32 | block_count |
| 20 | u32 | footer_flags (reserved, 0) |
| 24 | u32 | footer_crc: CRC-32C of bytes 0..23 |
| 28 | bytes(4) | magic `ZXE` 0x1A |

When the Footer is missing or damaged, a reader MAY rebuild the entry
list from inline records (streamed files) or report the archive as
damaged.
