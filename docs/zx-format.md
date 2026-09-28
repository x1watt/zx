# The .zx archive format, version 1 (draft specification)

Status: draft, implemented by zx 0.5.0 (`lib/src/format/zx`). The default
codec chain is intentionally not fixed by this document; it will be
chosen after benchmarking (section 12). The design rationale is in
`docs/zx-format-design.md`; the changes made while implementing it are
listed in section 15.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Conventions

- Byte order: little endian for all fixed-size integers.
- `u8`, `u16`, `u32`, `u64`: unsigned integers of that many bits.
- `vint`: unsigned LEB128. 7 bits per byte, low bits first, high bit set
  on every byte except the last. At most 10 bytes. A reader MUST reject a
  vint longer than 10 bytes or one whose value does not fit in 64 bits.
  Writers MUST use the shortest encoding. zx refuses values of 2^63 and
  more where a size, offset or count is expected.
- `svint`: a signed value as a vint of its zigzag encoding
  (`(v << 1) ^ (v >> 63)`).
- `string`: `vint length` then that many bytes of UTF-8, no terminating
  NUL. Readers MUST reject invalid UTF-8 in paths.
- `bytes(n)`: n raw bytes.
- `version`: three `u16`: major, minor, patch. Versions compare
  lexicographically.
- CRC-32C: the Castagnoli CRC (polynomial 0x1EDC6F41 reflected,
  0x82F63B78), initial value 0xFFFFFFFF, final xor 0xFFFFFFFF.
- Offsets are absolute byte offsets from the start of the file. In
  multi-volume sets, block locations are a volume number plus an offset
  in that volume, and Footer offsets refer to the volume that holds the
  Footer (section 10).

## 2. Overall structure

```
ZxFile = Header, { Block }, Index, Footer, { { Block }, Index, Footer }
```

A file MUST start with a Header and end with a Footer. Blocks carry data
and metadata. The Index is stored in one or more Index blocks
(block_type 5) followed by the Footer that locates it. With the
`appendable` feature (section 9) a file holds several Index and Footer
pairs, one per generation; the last valid Footer is the current one.

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

The Header is written once, when the archive is created: appending a
generation (section 9) never changes it. What a later generation needs is
in the requirements record of its Index (section 6, record 0x46).

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

Unknown bits in `optional_features` MUST be ignored. A reader MUST run
steps 4 and 5 again with the requirements record (0x46) of the Index it
reads, before it reads any data block of that generation.

A writer MUST set `min_reader_version` to the greatest "introduced in"
version (section 11) among: the format version itself, every codec and
filter used, every critical record type used, every required feature set.
It MUST set in `required_features` exactly the required features it uses
(for the Header: those of the first generation and the `appendable`
bit; zx also sets `solid` whenever solid blocks are enabled, and `dedup`
whenever deduplication is). The same rules give the requirements record of
every Index, where zx sets `solid` and `dedup` only when the extents of the
generation need them (section 6.4).

### 3.2 Feature bits

`required_features`:

| Bit | Name | Section |
|---|---|---|
| 0 | solid | Blocks holding data of several entries. |
| 1 | encryption | Section 7. |
| 2 | dedup | Entries share data chunks (section 6.4). |
| 3 | appendable | Several Index/Footer generations (section 9). |
| 4 | multi_volume | Section 10. |
| 5 | database | A database lives in the archive: Index record 0x49 and database page blocks (section 16). |
| 6..63 | | Reserved for future versions. |

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

`block_type`:

| Value | Use |
|---|---|
| 0 | data of one entry |
| 1 | solid data (data of several entries) |
| 2 | inline metadata (the records of a streamed file, section 8) |
| 3 | dedup chunk store |
| 4 | padding (payload ignored) |
| 5 | Index (section 6) |
| 6 | chunk run (section 6.4.1): an aid to writers, not a data block |
| 7 | database pages (section 16): not a data block |

Unknown block types MUST be treated as an error unless the block lies
outside every extent the Index references (then it MAY be skipped). A
sequential reader (section 8) does not know the extents before it meets
a block: it skips a block of a type it does not know, and numbers the data
blocks by their types (0, 1 and 3) only; an inline record that places an
entry in a skipped block fails that entry.

`check_type` and the check of the unpacked payload:

| Value | Check | n |
|---|---|---|
| 0 | none | 0 |
| 1 | CRC-32C | 4 |
| 2 | xxHash64 (seed 0, the u64 little endian) | 8 |
| 3 | SHA-256 | 32 |
| 4 | BLAKE2sp | 32 |

Block checks protect integrity; they are independent of the per-entry
SHA-256 (section 6.2), which identifies content. An encrypted block
(section 7) MUST use check_type 0: a check of the plaintext in the clear
header would identify its content, and the MAC protects the block.

Writers SHOULD keep `unpacked_size` of data blocks between 1 MiB and
64 MiB so that blocks can be coded in parallel; readers MUST accept any
size up to 2^40 and MAY refuse larger blocks. zx writes 16 MiB blocks by
default (4 KiB to 64 MiB with `-mbs`), cut at the block size in the
stream of the entries' data. A writer SHOULD store a block with chain 0
when its chain does not make it smaller.

### 4.1 Resynchronisation

A reader facing damage MAY scan forward for the marker `ZXB\x01` and accept
a block when its `header_crc` is valid. The sequential reader of zx does
this, then places the following entries by their inline records (section
8).

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

The data chains are declared in the Index (record 0x10) and, in streamed
files, in an inline metadata block before the first block using them.
The metadata blocks (types 2 and 5) are needed before the Index can be
read, so they use chain 0 or the chain of the Header record 0x0B. zx
gives that chain id 1 (LZMA2) and numbers the data chains from 2. A
chain id is never redefined in a file.

When a coder is undone, its output size is known when every coder before
it (in writing order) keeps the size (a filter): it is then the block's
unpacked_size. The payload formats of the codecs are in section 11.

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
value (odd values are critical). A writer that copies an entry into a new
generation SHOULD keep its unknown non-critical attributes.

### 5.1 Header records

| Type | Crit | Content |
|---|---|---|
| 0x02 | no | writer name: string (for example "zx 0.5.0 (Dart)") |
| 0x04 | no | creation time: vint nanoseconds since 1970-01-01 UTC |
| 0x05 | yes | KDF parameters (section 7) |
| 0x07 | yes | volume: vint volume number (0 based), vint volume count or 0 if unknown |
| 0x08 | no | archive comment: string |
| 0x0B | yes | metadata chain: Chain (section 4.2), the chain of the metadata blocks besides chain 0 |

## 6. Index

The Index is the unpacked content of one or more Index blocks
(block_type 5, at most 16 MiB unpacked each in zx), written one after the
other just before the Footer; their contents are concatenated. Its
location is given by the Footer. The content is a sequence of records:

| Type | Crit | Content |
|---|---|---|
| 0x10 | no | chain declaration: Chain (section 4.2) |
| 0x12 | no | block table (section 6.1) |
| 0x21 | yes | entry (section 6.2); one per item, in listing order |
| 0x30 | no | SHA-256 lookup table (section 6.5) |
| 0x32 | no | TLSH lookup list (section 6.5) |
| 0x34 | no | chunk table (section 6.4; written by zx 0.5.0 only) |
| 0x36 | no | chunk runs (section 6.4.1) |
| 0x40 | no | previous Index location (section 9.1) |
| 0x42 | no | generation number, time and comment (section 9.1) |
| 0x44 | no | generation list (section 9.1) |
| 0x45 | yes | volume table (section 10.2) |
| 0x46 | no | requirements of this generation: version min_reader_version, u64 required_features, u64 optional_features |
| 0x49 | yes | database root (section 16.1) |

Chain declarations and the block table MUST appear before the first entry.
A reader MUST check the requirements record (section 3.1) before it reads
the data of the generation; it is not critical because every reader of
format version 1 knows it.

### 6.1 Block table

```
BlockTable = vint block_count,
             block_count x ( vint offset, vint header_size_total,
                             vint packed_size, vint unpacked_size,
                             vint chain_id )
```

`offset` is the position of the block marker and `header_size_total` the
size of the whole block header (marker to header_crc), so the payload is
at `offset + header_size_total`. It lets a reader seek to any block
without scanning. Block numbers used by entries are indexes in this
table.

The table lists the data blocks (types 0, 1 and 3) of the file, in file
order, not the metadata blocks (types 2, 4, 5 and 6) nor the database
page blocks (type 7). In an appendable file the table of each
generation lists every data block written up to that generation: block
numbers stay the same across generations, and a new generation appends
its blocks at the end of the table.

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
| 0x62 | no | mtime: svint nanoseconds since 1970-01-01 UTC |
| 0x64 | no | atime (as mtime) |
| 0x66 | no | ctime, the status change time (as mtime) |
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
  `hash_table` optional feature), except in the clear Index of an
  encrypted archive (section 7). Readers that extract a file with a
  SHA-256 MUST verify it and report a mismatch as a data error.
- The inline records of a streamed file (section 8) follow other rules:
  they have no SHA-256, their `size` is absent when it was not known when
  the record was written, and their `extents` hold one triple (block,
  offset_in_block, 0): where the data starts.

### 6.3 TLSH

TLSH (Trend Micro Locality Sensitive Hash) digests allow finding similar
files. The digest is stored as its standard text form: `T1` followed by
70 hex digits (128 buckets, a 1 byte checksum, a sliding window of 5
bytes), as the reference implementation (github.com/trendmicro/tlsh)
prints it. Files smaller than the minimum TLSH input (50 bytes) or with
too little variation (half of the buckets or more empty) have no digest.
The TLSH variant (buckets, checksum length) is the one given by its text
form.

### 6.4 Dedup

With the `dedup` required feature, identical chunks are stored once (in
data or dedup chunk store blocks) and several entries' extents point to
them. The chunking algorithm is a writer choice and is not part of the
format.

A generation needs `dedup` (in its requirements record 0x46) when two
extents of its entries, of one entry or of two, share bytes of a block. A
reader needs nothing more than following the extents: the same block range
may be read for several entries, and a block may be used in part.

Dedup chunk store blocks (block_type 3) hold chunks one after the other.
They are listed in the block table and coded with a chain like data
blocks.

A writer that deduplicates across generations needs the chunks stored so
far. zx 0.5.0 kept them in a chunk table, written whole in every Index;
later writers keep them in chunk runs (section 6.4.1), MAY read a chunk
table to carry its chunks into a run, and SHOULD NOT write one:

```
ChunkTable (record 0x34) =
  vint chunk_count,
  u64  blocks_fingerprint,
  chunk_count x ( vint block_delta, vint offset, vint length,
                  bytes(32) sha256 )
```

- A chunk is `length` (at least 1) bytes at `offset` of block number
  `block`; it lies in one block (`offset + length` is at most the block's
  `unpacked_size`). `block` is the previous chunk's block plus
  `block_delta` (the first chunk's block is its `block_delta`). Chunks are
  sorted by block, then offset, and do not overlap. `sha256` is the
  SHA-256 of the chunk's bytes.
- `blocks_fingerprint` is the xxHash64 (seed 0) of the payload of the
  block table record (0x12) of the same Index, as written. A writer MUST
  ignore a chunk table whose fingerprint differs (a writer that did not
  know the record copied it after renumbering the blocks) and MUST check
  every chunk against the block table before it references it.
- The table is an aid to writers: readers ignore it. It lists chunks that
  a later generation may reference; they need not be used by an entry of
  this generation (zx keeps the chunks of deleted files until a
  compaction). A new generation MAY carry the table forward (with the
  fingerprint of its own block table) and add its chunks.
- A clear Index of an encrypted archive MUST NOT hold a chunk table
  (section 7).

zx (informative):

- Chunking is the fragmenter of zpaq 7.15 (Matt Mahoney, public domain):
  a hash `h = (h + c + 1) * M` over the bytes since the last cut, where
  `M` is 314159265 when an order 1 table (the last byte that followed the
  previous byte) predicted `c`, else 271828182, both mod 2^32; a cut
  follows the byte where `h < 2^(32 - k)` once the chunk has at least
  2^k / 16 bytes, or at 2^k * 127 / 16 bytes; the hash, the previous byte
  and the table restart at every cut and every file. The average chunk is
  2^k bytes, k = 16 (64 KiB) by default (`-mchunk=4k..4m`); a chunk is
  also at most the block size.
- Every chunk gets its SHA-256. A chunk known (from the chunk runs of
  the last generation, or stored in this one) is referenced; a new one is
  appended to the dedup chunk store block being filled, which is written
  when the next chunk does not fit (a chunk is never cut by a block
  boundary, except when a block is cut to fit a volume, section 10.1;
  such a chunk is left out of the runs). The chunks stored in this
  generation are held in memory (about 100 bytes each) and written as a
  run before the Index; the runs of earlier generations stay on disk.
- A file whose size and SHA-256 are those of a file of the last
  generation or of this one reuses its extents. The SHA-256 of the whole
  file is computed while it is chunked, so a file is read once and never
  held whole: when its size is that of a stored file, its new chunks wait
  in a temporary spill file until its hash is known, then are dropped (a
  copy) or stored; a file whose size was not known before is checked too,
  and its new chunks are dropped when they are all still in the block
  being filled.
- Streamed files (section 8) do not deduplicate: an entry's data is
  contiguous in them. `-mdedup=off` turns deduplication off; the chunk
  runs (and a chunk table of zx 0.5.0) of the last generation are then
  carried forward unchanged.

### 6.4.1 Chunk runs

A chunk run lists chunks sorted by SHA-256, in a block a writer searches by
random access (reading a few KiB for a lookup) instead of loading every
chunk. A run is a block of type 6 with chain 0, check_type 0 (its parts
carry their own checks), `unpacked_size` the size of its plaintext
payload; it is not in the block table and no extent points into it. In an
archive with the `encryption` feature the run is encrypted as a data
block (section 7: nonce, ciphertext, MAC; `packed_size` is
`unpacked_size + 48`), whether the metadata is encrypted or not.

The plaintext payload, every part starting at a multiple of 16 bytes (so
that AES-CTR decrypts it from its offset: the counter of the byte at
offset `o` is the nonce plus `o / 16`):

```
ChunkRun =
  u64 record_count                 (at least 1)
  u32 bloom_bytes                  (a multiple of 16, 0 for no filter)
  u8  bloom_probes                 (at most 32; not 0 with a filter)
  u8  6                            (log2 of the records of a page)
  u16 0
  record_count x Record            (pages of 64 records, the last one
                                    shorter)
  page_count x Fence               (page_count = ceil(record_count / 64))
  bytes(bloom_bytes) bloom
  bytes(16) trailer_check
Record = bytes(32) sha256, u32 block, u32 length, u64 offset
Fence  = bytes(8) first 8 bytes of the first sha256 of the page,
         bytes(8) page_check
```

- Records are sorted by `sha256` (bytewise), equal values adjacent (a
  writer SHOULD NOT write a hash twice). `block`, `offset`, `length` are
  as in the chunk table: the chunk is `length` bytes at `offset` of data
  block `block`.
- `page_check` of page `p` (its record bytes): the xxHash64 (seed 0, u64
  little endian) of them, or in an encrypted archive the first 8 bytes of
  HMAC-SHA-256(key_mac, 0x01, nonce, u64 p, the plaintext of the page).
- `trailer_check`: the xxHash64 of the 16 header bytes, the fences and the
  filter, as a u64 followed by 8 zero bytes, or in an encrypted archive
  the first 16 bytes of HMAC-SHA-256(key_mac, 0x02, nonce, the same
  plaintext bytes). A page read alone is checked by its fence, which the
  trailer check covers, so a writer does not read the whole run; keyed
  checks authenticate a page as the MAC authenticates the block.
- The Bloom filter has `m = 8 * bloom_bytes` bits (bit `i` is bit `i mod
  8` of byte `i / 8`). A hash sets bits `(h1 + i * h2) mod 2^32 mod m` for
  `i` from 0 to `bloom_probes - 1`, where `h1` and `h2` are the u32 (little
  endian) at bytes 8 and 12 of the SHA-256 and `h2` is made odd (`| 1`). A
  hash with a clear bit is not in the run.

The Index record 0x36 lists the runs that hold the chunks known to the
generation, oldest first:

```
ChunkRuns (record 0x36) =
  u64  blocks_fingerprint,
  vint run_count,
  run_count x ( [vint volume, with multi_volume] vint offset,
                vint size, vint record_count )
```

`offset` is the position of the block marker, `size` the size of the
whole block. `blocks_fingerprint` is the one of the chunk table (the
xxHash64 of the payload of the block table record of the same Index); a
writer MUST ignore a list whose fingerprint differs, and MUST check a run
(its block header: type 6, chain 0, the sizes; its header against the
record count; its trailer check) before it uses it, and every record it
uses against the block table. A damaged page counts as holding no chunk.
A run of an older generation whose volume is missing is not used.

Readers ignore runs. A clear Index of an encrypted archive MAY hold record
0x36 (it holds no hash; the runs are encrypted).

zx (informative): each generation writes the chunks it stored as a new
run of at most 2^20 records (and what an empty volume holds), merged with
the last runs while each of them is not full and holds at most 4 times
the records gathered so far (size tiers: a chunk is written again a few
times, the runs number grows with the logarithm of the chunks); merged
runs stay in the file until a compaction. A writer keeps the fences and
the filters in memory (1.5 bytes a chunk at 10 bits and 7 probes a chunk,
about 1% of false positives) and reads one page of 3 KiB for a lookup the
filter lets through.

### 6.5 Lookup tables

For fast search without reading every entry:

```
Sha256Table = vint count,
              count x ( bytes(32) sha256, vint entry_number )
              sorted by sha256 ascending (binary search), then by
              entry_number
TlshList    = vint count, count x ( string tlsh, vint entry_number )
```

`entry_number` is the position of the entry in the Index (0 based). The
tables list the files that have the attribute.

## 7. Encryption

Feature bit `encryption`. Parameters in header record 0x05:

```
Kdf = vint kdf_id, vint params_size, bytes(params_size)
      vint cipher_id,
      bytes(16) password_check
```

- `kdf_id` 1: scrypt (RFC 7914), params `vint log2_N, vint r, vint p,
  bytes(32) salt`. The input is `P = SHA-256(UTF-8 password)` and the key
  material is `scrypt(P, salt, N = 2^log2_N, r, p, dkLen = 64)`. zx
  writes log2_N 15, r 8, p 1 by default (`-mkdf` changes log2_N) and reads
  log2_N up to 24.
- `cipher_id` 1: AES-256-CTR with HMAC-SHA-256 (encrypt then MAC).
  The KDF output is 64 bytes: 32 for AES, 32 for HMAC.
- Each encrypted block payload is `bytes(16) nonce, ciphertext,
  bytes(32) mac`, where the MAC covers the block header fields before the
  CRC (marker to check), the nonce and the ciphertext. `packed_size`
  includes nonce and MAC. The nonce is random and is the first counter
  block; the counter is incremented as a 128 bit big endian number for
  each 16 bytes (NIST SP 800-38A).
- `password_check`: first 16 bytes of HMAC-SHA-256(key_mac, "zx password
  check"), letting a reader reject a wrong password before decoding.
- Without `encrypted_metadata`, only data blocks are encrypted. With it,
  metadata blocks (Index, inline records) are encrypted too, so names and
  sizes are hidden. zx encrypts the metadata by default when it is given
  a password (`-mhe=off` keeps the names visible).
- A clear Index of an encrypted archive MUST NOT hold SHA-256 or TLSH
  attributes, nor the lookup tables and the chunk table (section 6.4):
  they would identify the encrypted content. It MAY list chunk runs
  (record 0x36): runs of an encrypted archive are encrypted blocks
  (section 6.4.1).

Other KDFs (for example Argon2id) and ciphers are added as new ids with
their "introduced in" versions.

## 8. Streamed files

Header flag `streamed`: every entry is also written in an inline metadata
block (block_type 2), which a reader on a non-seekable input decodes in
order. The Index and Footer are still written at the end. The rules:

- An inline metadata block precedes the data block in which the data of
  its entries starts. It holds the declarations of the chains not
  declared before (a chain is declared before the first block that uses
  it, possibly in an inline block without entries), and the records of
  the entries added since the previous inline block, in listing order:
  those whose data starts in the next data block and those without data
  (section 6.2 for their form). Entries without data after the last data
  block go into an inline block before the Index.
- The data of the entries follows in stream order. An entry with a
  `size` takes that many bytes, across data blocks; an entry without a
  `size` starts a new data block and ends at the next inline metadata
  block that holds an entry record, or at the Index (the writer ends its
  last block with it).
- A reader that meets damage resynchronises (section 4.1). The entries
  whose data was in the lost part are reported as damaged; the next inline
  records give the block number and offset of the following entries
  (their extent), so the reader places them again (it counts the data
  blocks from the start of the file; after damage the first extent of the
  next inline block gives the number of the next data block).
- When the Footer or the Index of a streamed file is missing or damaged,
  a reader MAY read it this way instead.

### 8.1 Generations in a stream

An appended streamed file (section 9) holds its generations one after the
other: each writes the inline records of the entries it adds or changes
(its `0x76` is that generation), then its data, Index and Footer. Entries
it keeps, renames or deletes have no inline record: only its Index, after
all of its data, gives the state of the generation. So:

- A reader that gives the state of a generation (the last one by default)
  MUST take it from the Index of that generation: an entry is in the
  state when that Index lists it. It MUST NOT give as current an entry
  that a later generation replaced (a later inline record or Index entry
  with the same path) or deleted (absent from the Index).
- A reader of a non-seekable input can not know, when it meets the data of
  an entry, whether a later generation replaces or deletes it: that is
  written after, and earlier bytes are never changed. It MUST either keep
  the input until the Index it needs (zx copies a pipe to memory or to a
  temporary file, then reads it as a file, which also allows choosing
  a generation), or give every version in stream order, the later
  replacing the earlier as in tar, and report that entries deleted by a
  later generation were given (zx `-mpipe=onepass`).
- A sequential reader numbers generations by the Footers it passes and MAY
  decode the Index blocks it meets to learn each state; without a valid
  Index it can apply replacements (the last inline record of a path) but
  not deletions, and SHOULD say so.

## 9. Appendable files and compaction

Required feature `appendable`. This is the normal update mode of zx for
`.zx` archives: an update never rewrites existing bytes. A streamed file
stays streamed: every generation writes its inline records.

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
| 0x40 | no | previous Index: [vint volume, with multi_volume] vint offset, vint size (absent in generation 1) |
| 0x42 | no | generation: vint number, vint time (ns since epoch), string comment |
| 0x44 | no | generation list: vint count, count x ( vint number, vint time, vint volume, vint index_offset, vint index_size, string comment, vint added, vint deleted, vint packed ) |

The size of an Index location is its `index_size` (its Index blocks,
without the Footer). The generation list holds every generation up to and
including this one; the entry of this one has offset and size 0 (it is
located by the Footer). `added` counts the entries this generation wrote
or changed (their 0x76 is this generation), `deleted` the paths of the
previous generation that are gone, `packed` the bytes of the data blocks
it wrote. A reader lists the generations and opens any of them from this
record alone.

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
  time for display (`zx l -mgenerations`).
- A generation can be selected by number or by date (`-mversion=N`,
  `-mversion=YYYY-MM-DD[ HH:MM[:SS]]`, a `T` may separate date and time):
  a date `D` (or date and time) selects the last generation whose time is
  before the end of `D` (the end of that day, minute or second) in local
  time. Example: "the archive as of 2026-09-01".
- File timeline (`zx l -mtimeline=path`): for one path, zx walks the
  generations and reports each distinct version of that file (different
  SHA-256) with the date of the generation that introduced it, and the
  generation where it was replaced or deleted, if any. Entry attribute
  0x76 makes this cheap: zx walks back from the last generation and skips
  the generations in which a version stayed the same.

Entry attribute for timelines:

| Type | Crit | Content |
|---|---|---|
| 0x76 | no | since generation: vint, the generation that wrote this content of the entry (unchanged entries carry the value forward; a rename writes the current generation) |

An update in place appends to the file. When the file can not be opened
for writing (another program holds it, for example without sharing
writing on Windows), a writer MAY write the file again, its bytes up to the
last valid Footer followed by the new generation (the same bytes as an
append), and then replace the old file by a rename; the old file stays
as it was when the rename fails. zx does this, trying the rename again for
about 3 seconds.

Crash safety: an update interrupted before its Footer is complete leaves a
trailing partial generation. A reader MUST use the last Footer whose
`footer_crc` is valid and whose Index decodes; bytes after it are ignored,
and the next update SHOULD overwrite them (the one case where existing
bytes are replaced: garbage after the last valid Footer). zx finds that
Footer by its magic, scanning back from the end.

### 9.2 Compaction

Data of deleted or replaced entries stays in the file until the archive is
compacted. Compaction is an operation of the writer, not a structure:

- It writes a new file (then atomically renames it over the old one)
  holding only the blocks referenced by the current generation (or, with
  a "keep last N generations" option, by the last N generations), with a
  new block table, fresh Indexes and Footer.
- Blocks are copied as they are, without recompression, when all of their
  content is still referenced. Blocks that are only partly referenced
  (solid or dedup blocks) MAY be repacked; the writer chooses. (An
  encrypted block copied whole stays valid since its MAC does not cover
  its position.) zx repacks them: the referenced ranges of the partly used
  blocks of one chain are decoded, put one after the other into new
  blocks of the block size (a range goes whole to the next block when it
  does not fit, and is cut only when it is larger than a block), coded
  again with the chain rebuilt from the old chain's props (or the chain
  of `-m0` when it is given) and written after the copied blocks. A chain
  whose props do not give its settings (a zpaq coder without its method,
  written by zx 0.5.0) is not rebuilt: its blocks are copied whole, unless
  `-m0` is given. The extents of the kept generations follow the ranges to
  their new places. The chunks of the last kept generation (its runs, or
  a chunk table of zx 0.5.0) that lie whole in referenced bytes are
  written at their new places as runs for its Index; the earlier kept
  generations get none (only the last Index serves a writer).
- A database (section 16) is compacted with the files: the page blocks
  that the map pages of the kept generations use are copied whole, and
  the map pages are written again (each distinct one once) with the new
  places; the database roots of the kept Indexes point to them.
- The compacted file keeps the archive_id and restarts the generation
  history at the kept generations (their numbers and times are preserved).
  zx writes the blocks, then for each kept generation, oldest first, its
  Index and a Footer.
- Writers SHOULD report how much space compaction would free (the sum of
  unreferenced block bytes) so tools can suggest it, and MAY compact
  automatically when the wasted fraction exceeds a user setting. (zx
  shows it as `Wasted` in `l -slt`: the blocks the last generation does
  not use, and the packed share of the unused bytes of the blocks it uses
  in part.)

## 10. Multi-volume sets

Required feature `multi_volume`. Used when an archive must be split into
files of a given size, for example to spread it over several disks.

### 10.1 Volumes

- Volumes are named `name.zx.001`, `name.zx.002`, ... (three digits, more
  when needed); the file number is the volume number (0 based) plus 1.
  The first volume may also be named `name.zx`.
- Each volume is a complete, self-identifying file: it starts with a
  Header carrying the set's `archive_id` and a volume record 0x07 with its
  number, and ends with a volume trailer (section 10.3) or, when a
  generation ended in it, with that generation's Footer. A reader can
  therefore tell which archive and which position a file belongs to, even
  after files were renamed or moved.
- A block MUST lie entirely inside one volume. The writer starts a new
  volume when the next block does not fit. Blocks larger than a volume
  are written with a smaller block size, never split. (This keeps every
  volume independently readable, and a missing volume only affects the
  entries whose extents use it.) zx cuts a block that does not fit so
  that its first part fills the current volume, and codes the parts again.
- Volume sizes need not be equal: each volume has its own size limit
  (section 10.4).
- The Index and the Footer MUST be in one volume, the last one; that
  volume may exceed its size limit when the Index does not fit.

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
| 0x45 | yes | volume table: vint count, count x ( vint number, string file name, vint size, u64 xxHash64 of the whole volume file ) |

The entry of the volume that holds this Index has size 0 and hash 0 (the
file is not complete when the table is written).

### 10.3 Volume trailer

Every volume that does not end with a Footer ends with a 32-byte trailer:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | volume number |
| 4 | u32 | reserved (0) |
| 8 | u64 | data size of this volume (header included, trailer excluded) |
| 16 | bytes(8) | first 8 bytes of archive_id |
| 24 | u32 | CRC-32C of bytes 0..23 |
| 28 | bytes(4) | magic `ZXV` 0x1A |

The last volume ends with the normal Footer (section 14), whose offsets
refer to that volume.

### 10.4 Writing (informative, zx options)

- A volume size, or a list of sizes, one per volume, the last one
  repeating (for example "first 4 GiB, then 25 GiB each": `-v4g -v25g`, or
  `-mvsizes=4g,25g`).
- A list of destination directories, each optionally with a size budget
  or "until the disk is full" (free space checked before each volume):
  volumes are written to the first directory until its budget is used,
  then to the next (`-mvdir=/mnt/disk1:12g -mvdir=/mnt/disk2:full`). A
  volume in a directory whose budget is almost used is made smaller to fit
  it. The free space comes from `df -Pk` (POSIX) or PowerShell (Windows);
  when the tool is missing or fails, the volume reserves its space as it
  is written, by writing zeros up to 96 MiB ahead of its data (the zeros
  left at its end are cut off): the volume ends where a reservation fails,
  and the next one goes to the next directory. (On copy-on-write file
  systems a reservation does not guarantee the space.)
- Appending a generation to a multi-volume archive never rewrites earlier
  volumes: the new blocks, Index and Footer go into new volumes after the
  last one, which keeps its Footer. Old volumes can stay on read-only or
  offline disks.
- Compaction rewrites the whole set, with the same options.

### 10.5 Reading (informative, zx options)

- A list of search directories where volumes may be found, in addition to
  the directory of the file that was opened (`-mvsearch=DIR`, one per
  disk). Volumes are identified by their Header (`archive_id` and volume
  number), so their file names and locations do not matter.
- Only the volumes holding the requested blocks are opened: listing needs
  only the last volume; extracting one file needs only the volumes of its
  extents.
- The last volume is the one with the highest number that ends with a
  valid Footer (a newer volume without one is an interrupted append). When
  the highest volume found ends with a trailer, the next one is missing.
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

Initial standard entries (introduced in zx 0.5.0). The payload is the
output of the coder for the whole block; a decoder is given the block's
unpacked size when it is the output size (section 4.2).

| Id | Name | Props | Payload | zx |
|---|---|---|---|---|
| 0 | store | none | the data | read, write |
| 1 | LZMA2 | 1 byte dictionary size code (as 7z) | an LZMA2 stream, with its end byte 0x00 | read, write |
| 2 | LZMA | 5 bytes (as 7z) | a raw LZMA stream (end marker optional) | read, write |
| 3 | zstd | vint window_log (informative) | zstd frames (RFC 8878) | read |
| 4 | PPMd7 (var.H) | 5 bytes (as 7z) | the 7z PPMd stream | read, write |
| 5 | PPMd8 (var.I) | u16: order - 1 (bits 0-3), memory in MB - 1 (bits 4-11), restore method (bits 12-15), as zip method 98 | the range coded symbols after the zip parameter word, ending with the end marker | read, write |
| 6 | BZip2 | none | a .bz2 stream | read, write |
| 7 | Deflate | none | raw Deflate (RFC 1951) | read, write |
| 8 | zpaq | none, or the zpaq method that wrote the block as UTF-8 text (`1` to `5`, or an expert method such as `x4.3ci1`); decoders ignore it (the zpaq block header, with its config, is inside the payload) | one zpaq block (libzpaq level 1 or 2 stream) | read, write |
| 9 | LZ4 | none | LZ4 frames (zx writes one frame of independent blocks, without checksums) | read, write |
| 10 | LZO1X | none | an LZO1X stream with its end marker | read |
| 0x40 | BCJ x86 | none, or u32 start offset | filtered data | read, write |
| 0x41 | ARM | as 0x40 | as 0x40 | read, write |
| 0x42 | ARMT | as 0x40 | as 0x40 | read, write |
| 0x43 | ARM64 | as 0x40 | as 0x40 | read, write |
| 0x44 | PPC | as 0x40 | as 0x40 | read, write |
| 0x45 | SPARC | as 0x40 | as 0x40 | read, write |
| 0x46 | IA64 | as 0x40 | as 0x40 | read, write |
| 0x47 | RISCV | as 0x40 | as 0x40 | read, write |
| 0x48 | Delta | 1 byte distance - 1 | as 0x40 | read, write |

The branch filters convert the whole block in one pass with the functions
of Bra.c (the bytes at the end that no instruction covers stay as they
are).

Experimental candidates for benchmarking (ids in 0x10000+, to be assigned
when implemented): cmix, paq8 variants, NNCP-style neural compressors, and
other high-ratio context-mixing models. (The zcm family of zx registers
at 0x10000; `registerZxCodec` in `lib/src/format/zx/zx_codecs.dart`.)

## 12. Default codec selection

Not part of the format. The zx writer's defaults (which chain for which
content and level) will be decided after benchmarking the candidates on
representative data (text, source code, binaries, firmware, media), and
documented separately. Until then zx 0.5.0 writes LZMA2 at the level of
`-mx` (5 by default, the dictionary at most the block), solid 16 MiB
blocks, xxHash64 block checks, and metadata with LZMA2, and deduplicates
with 64 KiB chunks (section 6.4). The blocks are coded by worker isolates,
as many as `-mmt` gives and as fit in a memory limit (`-mmemuse`, by
default 75% of the available memory and at most the available memory
minus 1.5 GiB): each worker's memory is estimated from the chain (the
LZMA dictionary, the PPMd model, the zpaq method, the zcm budget).

## 13. Reading algorithm (informative)

1. Read the Header, run the compatibility check (3.1).
2. Seekable: read the Footer (the last valid one), read the Index blocks,
   decode records, check the requirements; non-seekable with `streamed`:
   read blocks in order, use inline records, and apply the generations
   as section 8.1 says (zx copies the input and reads it as a file).
3. For each entry to extract: for each extent, decode (or reuse from a
   cache) its block, copy the range; verify the block check and, at the
   end, the entry SHA-256. zx decodes the blocks the entries need in
   worker isolates, in the order the entries use them, and starts a
   decoder only while the estimated memory of those in flight stays under
   its limit (from the chain's props: the PPMd model size, the zcm
   budget; one decoder always runs).

## 14. Footer

Last 32 bytes of the file (of the last volume), and of each generation:

| Offset | Type | Field |
|---|---|---|
| 0 | u64 | index_offset (marker of the first Index block) |
| 8 | u64 | index_size (bytes from index_offset to the footer) |
| 16 | u32 | block_count (entries of the block table) |
| 20 | u32 | footer_flags (reserved, 0) |
| 24 | u32 | footer_crc: CRC-32C of bytes 0..23 |
| 28 | bytes(4) | magic `ZXE` 0x1A |

When the Footer is missing or damaged, a reader MAY rebuild the entry
list from inline records (streamed files) or report the archive as
damaged.

## 15. Changes to the draft

Changes made while implementing the draft in zx 0.5.0:

1. **Index blocks have their own type** (5). Type 2 is only for the
   inline records of streamed files, so a reader in one pass tells them
   apart; the Index is "one or more Index blocks just before the Footer".
2. **Metadata chain in the Header** (record 0x0B, critical): the Index
   blocks must be decoded before the chains of the Index are known, so
   their chain is chain 0 or the one of the Header.
3. **Requirements per generation** (Index record 0x46): the Header is
   never rewritten, so a later generation that uses a newer codec or
   feature says so in its Index; readers check it as they check the
   Header.
4. **Generation list** (Index record 0x44): every generation with its
   time, Index location and counts, so generations are listed and opened
   without reading every Index.
5. **Block table**: data blocks only, cumulative across generations
   (stable block numbers); `header_size_total` is the whole block header.
   `block_count` of the Footer is the number of table entries.
6. **Times** are svint (zigzag) in every case.
7. **Streamed files**: where inline blocks go, chains declared before
   their first use, sizes and the start extent in the inline records, the
   end of an entry without size, resynchronisation (section 8).
8. **Encryption**: the scrypt input and output, the CTR counter, check
   type 0 for encrypted blocks, no content hashes in a clear Index of an
   encrypted archive (section 7).
9. **Volumes**: a volume that ended a generation keeps its Footer (the
   draft said both that earlier volumes are never rewritten and that the
   last one's Footer is replaced by a trailer); the volume table entry of
   the last volume has size 0; the Index and Footer are in the last
   volume; the trailer's data size excludes the trailer.
10. **0x40** carries the volume in multi-volume sets; its size is the
    `index_size`.
11. **Codec payloads** (section 11): the payload format of each codec,
    the PPMd8 props word, the output size given to decoders, the codecs
    zx 0.5.0 reads only (zstd, LZ4, LZO1X).
12. The writer stores a block that its chain does not make smaller with
    chain 0; `0x76` is the current generation after a rename.

Changes made in zx 0.5.0 when the writer learned deduplication (the
format version and the reader requirements do not change: every reader
of format version 1 follows shared extents, and the new record is not
critical):

13. **Chunk table** (Index record 0x34, section 6.4): the location, length
    and SHA-256 of every chunk a deduplicating writer stored, with the
    fingerprint of the block table it was written for, so that appended
    generations deduplicate against all earlier data and a table made
    stale by an older writer is detected. Not in a clear Index of an
    encrypted archive.
14. **When `dedup` is required**: when two extents of a generation share
    bytes (section 6.4); the Header of a new archive has it when the
    writer deduplicates, as `solid` when it writes solid blocks.
15. **Dedup chunk store blocks** (type 3) are what zx writes with dedup:
    chunks one after the other, never cut by a block boundary.
16. **Compaction repacks** blocks that are only partly referenced (section
    9.2) instead of copying them whole, and `Wasted` counts their unused
    share.

Changes made after zx 0.5.0 (the format version and the reader
requirements do not change: readers ignore the new block type and record,
and a reader of zx 0.5.0 reads the new files):

17. **Chunk runs** (block type 6, Index record 0x36, section 6.4.1): the
    chunks of a deduplicating writer, sorted by SHA-256 in blocks searched
    by random access, with fences, a Bloom filter and page checks (keyed
    in an encrypted archive). Each generation writes its new chunks as a
    run; runs are merged in size tiers. They replace the chunk table
    (0x34), which held every chunk in every Index (40 bytes a chunk each
    time) and had to be loaded whole into memory by the next writer. A
    writer reads a chunk table of zx 0.5.0 and carries its chunks into a
    run. Measured on 1,638,400 simulated chunks (100 GiB of unique data at
    64 KiB): a run of 77 MB written once (and at merges) instead of 58 MB
    more in every Index, and 2.4 MB (1.5 bytes a chunk) in the writer's
    memory instead of about 250 MB (`docs/performance.md`).
18. A clear Index of an encrypted archive may list chunk runs (they hold
    no hash in the clear), so such archives deduplicate across
    generations.
19. **zpaq props** (section 11): the method that wrote the block, so that a
    compaction repacks with it; decoders ignore the props. Blocks without
    it are copied whole by a compaction (section 9.2).

Ambiguities of the specification found while implementing the above,
settled here:

20. Section 8 did not say what a reader of an appended streamed file gives:
    the inline records of a generation are only its new or changed
    entries, so a one pass reader met the data of entries that a later
    generation deletes or replaces. Section 8.1 now says that the state of
    a generation comes from its Index, and what a reader of a
    non-seekable input does.
21. Section 4 required an error for an unknown block type unless it lies
    outside the extents of the Index, which a sequential reader does not
    know: it skips such a block and numbers data blocks by their types
    only.
22. Section 11 gave zpaq "no props" without saying whether a decoder
    checks that: decoders ignore them, so writers may store the method.
23. Section 9.1 said that an update never rewrites existing bytes; a
    writer that can not open the file for writing may produce the same
    bytes in a new file and rename it over the old one (section 9.1).
24. Section 6.1 listed the blocks of the block table without naming the
    others: every metadata block (types 2, 4, 5 and 6) is outside it.
25. Section 10.4 said that the free space is checked before each volume
    without saying how when the system does not tell: the volume reserves
    its space as it is written.

Changes made for zxdb, the database in the archive (the format version
does not change; the new required feature `database` makes readers that
do not know it refuse the generations that hold a database, and the
generations before the first database commit stay readable by them):

26. **Feature bit 5, `database`** (section 3.2), required by every
    generation whose Index holds record 0x49. zx sets it in the
    requirements record (0x46) of such generations; the Header of an
    archive made for a database does not have it (its first generation
    holds no database).
27. **Block type 7, database pages** (section 16.2): pages of the
    database, coded, checked and encrypted as data blocks, outside the
    block table (so that a commit does not grow the block table that
    every Index holds) and located by the page map.
28. **Index record 0x49, database root** (section 16.1), critical: the
    page map, the catalog, the free page ids. File updates carry it
    unchanged; a compaction rewrites its map pages (section 9.2).
29. **LZ4 is written** (section 11): one frame of independent blocks,
    without checksums (the block check covers the data). It is the codec
    of the database's write buffer and of `fast` trees. zx 0.5.0 already
    reads such blocks.
30. **Writers take a lock** (informative, zx): a database writer, an
    update and a compaction of an archive that has a database (or whose
    lock file exists) hold `<archive>.zx-lock` (an exclusive lock of the
    file, per process, with a marker file per process for its isolates),
    and an update or a compaction refuses an archive that another writer
    appended to after it was opened.

## 16. Database (zxdb)

Required feature `database`. An archive may hold a database next to its
files (docs/zxdb-design.md): ordered maps of byte strings ("trees") kept
in copy-on-write B+trees of logical pages. Every database commit is a
generation of the archive (section 9): it appends the page blocks of the
pages it wrote, the map pages that changed, and an Index whose record
0x49 is the new database root; the entries of the files are those of the
previous generation. A generation that changes only files carries record
0x49 unchanged. The database of generation N is read from the record
0x49 of its Index, so every generation keeps its database state (time
travel), until a compaction.

A database lives in single-file archives only (no `multi_volume`: page
locations are offsets in the file).

### 16.1 Database root (Index record 0x49, critical)

```
Database =
  vint version            (1)
  vint next_page_id       (page ids are 1 to next_page_id - 1)
  vint catalog_root       (page id of the catalog tree's root, 0: none)
  vint next_tree_id       (the number of the next tree)
  vint unfolded_bytes     (bytes of pages in the write buffer, 16.5)
  vint map_log2           (10: 1024 page ids per map page)
  vint map_count,         map_count x MapRef
  vint free_count,        free_count x ( vint start_delta, vint length )
MapRef = vint 0 (no map page, its ids have no page) | Loc
Loc    = vint block_offset (not 0), vint block_size, vint in_offset,
         vint length, vint flags
```

- A reader MUST refuse a version it does not know. `map_count` is
  `((next_page_id - 1) >> 10) + 1` (0 when next_page_id is 1); map page
  `k` gives the places of page ids `k * 1024` to `k * 1024 + 1023` (id 0
  is never a page).
- A Loc is where a page is: the database page block whose marker is at
  `block_offset` and which is `block_size` bytes long (header included),
  and the page's `length` bytes at `in_offset` of its unpacked payload.
  `flags` as in the map pages (16.3).
- The free list holds the page ids that the generation does not use and
  that a later commit may give to new pages, as runs: `start` is the end
  of the previous run (0 for the first) plus `start_delta`. A page id
  freed by a generation may name another page in a later one; each
  generation reads its own map, so earlier generations are not affected.

### 16.2 Database page blocks (block type 7)

A block of type 7 holds pages one after the other; its payload has no
other structure (the Locs give the pages). It is coded with a chain
declared in the Index (record 0x10), its check is that of a data block,
and in an archive with the `encryption` feature it is encrypted as a
data block (section 7). It is not in the block table and no extent
points into it; a sequential reader skips it (section 4).

zx (informative) writes at commit blocks of about 64 KiB of pages (LZ4
for the write buffer, 16.5), and at fold blocks of about 256 KiB coded
with the tree's chain; the unit of a cold read is a block.

### 16.3 Map pages

A map page is 24,576 bytes, the Loc of 1024 page ids as fixed entries:

| Offset | Type | Field |
|---|---|---|
| 0 | u64 | block_offset (0: no page for this id) |
| 8 | u32 | block_size |
| 12 | u32 | in_offset |
| 16 | u32 | length |
| 20 | u32 | flags |

`flags`: bit 0 set while the page is in the write buffer (16.5); bits 16
to 31 the number of the page's tree (0 for the catalog, 0xFFFF for a tree
numbered 0xFFFF or more); the other bits are 0. Map pages are stored in
database page blocks like the other pages (zx: LZ4) and located by the
MapRefs of the root.

### 16.4 Tree pages

```
Leaf     = u8 1, vint count, count x ( vint shared, vint suffix_length,
           bytes(suffix_length) suffix, vint vtag, value )
Branch   = u8 2, vint count, vint child_0,
           count x ( vint shared, vint suffix_length,
                     bytes(suffix_length) suffix, vint child )
Overflow = u8 3, bytes (a part of a value)
```

- Keys are compared as unsigned bytes, a shorter key first on a common
  prefix. A key is `shared` bytes of the previous key of the same page
  (0 for the first) followed by `suffix`. Keys of a page are strictly
  increasing.
- Leaf values: `vtag` even: the value is the next `vtag >> 1` bytes; odd:
  the value is `vtag >> 1` bytes long and stored in overflow pages:
  `vint page_count`, then `page_count` page ids (vint), whose data
  concatenated in order is the value. Several values may name the same
  overflow pages (zx stores identical large values once: the tree
  `zx$blob` maps `'s'` and the SHA-256 of a value to `'p'` and its first
  page id as a u64 big endian, and that key to vint references, vint
  length, vint page count, the page ids and the SHA-256; readers do not
  need it).
- A branch with `count` keys has `count + 1` children: `child_0` holds the
  keys lower than `key_1`, `child_i` those at least `key_i` and lower than
  `key_i+1`. A separator need not be a key of a leaf.
- The size of a page is not limited by the format; zx keeps tree pages
  under the tree's page size (4 KiB to 64 KiB, 16 KiB by default), puts
  values longer than a quarter of it in overflow pages of 64 KiB, and
  keys are at most 1024 bytes.

### 16.5 The catalog, the write buffer

The catalog is a tree (root `catalog_root`): key the UTF-8 name of a
tree, value

```
CatalogRecord = vint version (1), vint tree_number, vint root_page_id
                (0: empty), vint entry_count, vint page_size (0: the
                store's default), vint has_compression,
                [ string compression, when has_compression is 1 ]
```

`compression` names the tree's policy: `store`, `fast`, `balanced`,
`max`, `ultra`, or a coder chain as the `-m` switch writes it (for
example `zcm:level=7:mem=1g`, coders separated by `+`). A reader does not
need it: every page block names its chain.

Write buffer (informative, zx): pages of trees whose policy is not
`store` or `fast` are written at commit with LZ4 and flag bit 0 set, and
`unfolded_bytes` counts them; a fold codes them again with the tree's
chain in larger blocks and clears the flag, in a generation of its own.
A reader reads both alike.

Tree names starting with `zx$` are the database's own (`zx$kv`,
`zx$blob`); the other `zx_` trees belong to the system and metadata
tables (docs/zxdb-design.md).

### 16.6 Key-value stores (informative, zx)

A KV store `name` is the tree `kv:name`; its settings are in the tree
`zx$kv` (key the name, value vint 1, vint default ttl in ms or 0, vint
flags: bit 0 some value has a ttl). A stored value is `u8 0, value` or
`u8 1, u64 expiry (ms since 1970-01-01 UTC), value`; a value whose expiry
has passed is absent, and a fold or a compaction removes it.
