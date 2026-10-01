# zx command line reference

Detailed reference of the zx command line (moved from the README). The README has the overview.

## Commands and switches

The package includes 7zr's command line as the `zx` program, with the same
commands and switches as 7-Zip:

```sh
zx <command> [<switches>...] <archive> [<files>...]
zx a -mx9 backup.7z docs/
zx x -psecret backup.7z -oout
zx l -slt backup.7z
zx a site.zip public/ -mm=deflate -mx9
zx a -psecret -mem=AES256 private.zip notes/
zx a src.tar.gz src/            # a tar written straight into gzip
zx x release.tar.xz -oout
zx a old.lzh docs/ -mm=lh7
zx t backup.arj
zx a backup.zpaq docs/          # a new version of a zpaq backup
zx l backup.zpaq -mversion=2    # as it was after version 2
zx a backup.zx docs/            # a new generation of a .zx archive
zx x backup.zx -mversion=2026-09-01 -oold   # as of a date
```

The format comes from the extension (`-t` chooses it: `-tzip`, `-ttar`,
`-tgzip`, `-tbzip2`, `-tLzh`, `-tArj`, `-tRar5`...), and the `-m`
switches are the ones 7-Zip has for that format.

**Compressed tar archives.** 7-Zip opens `x.tar.gz` as a gzip archive that
holds one file, `x.tar`. `zx` treats a tar inside gzip, bzip2, xz or lzma
as one archive when the names say so (`x.tar.gz`, `x.tgz`, `x.tar.bz2`,
`x.tbz2`, `x.tar.xz`, `x.txz`, `x.tar.lzma`, `x.tlz`..., or a stored name
ending in `.tar`): `l` lists the tar items (with a block for each level,
as 7-Zip prints nested archives), `x`, `e` and `t` read the tar in one
pass through the decompressor, `a` writes the tar straight into the
compressor, and `a`, `u`, `d` and `rn` on an existing archive decompress
the tar to a temporary file (in the `-w` folder or next to the archive),
update it and write the new archive in its place. `-m` switches go to the
compressor (`-mx`, `-mmt`...), except `-mm=gnu|pax|posix`, `-mtm`, `-mtc`,
`-mta`, `-mtp` and `-mcp`, which go to tar. `-ttar` opens any compressed
tar this way, and so does the type chain `-ttar.gzip` (7-Zip's order:
tar inside gzip). `-tgzip`, `-tbzip2`, `-txz` and `-tlzma` keep 7-Zip's
view of one compressed file.

**zpaq archives** are journals: every `a`, `u`, `d` or `rn` appends a new
version and never rewrites the old ones (the new file is the old one plus
the version). Files are cut into fragments and a fragment already stored
in any version is not stored again; unchanged files cost nothing, a
deleted file is recorded as a deletion, a renamed one reuses its
fragments. `l`, `x`, `e` and `t` show the last version, or the version N
with `-mversion=N` (`l -slt` prints `Versions` and each item's
`Version`); an archive opened at an older version is not updated.
Methods: `-mx=0` to `-mx=5` (zpaq's levels, default 1; higher values are
5) or `-mm=<zpaq method>` (`14`, `x4.3ci1`...), `-mfragment=N` (zpaq
`-fragment`), `-mhash=xxh64|sha1|off` (the zpaqfranz file hash, default
XXHASH64). `-p` encrypts a new archive as zpaq `-key` does (AES-256 in CTR
mode, scrypt); an encrypted archive has no signature and is recognized by
its `.zpaq` extension (or `-tzpaq`). The update runs on one thread
(`-mmt` is accepted and ignored). Archives stay readable and writable by
zpaq 7.15 and zpaqfranz, in both directions.

### The .zx format

`.zx` is zx's own container (specification: `docs/zx-format.md`, design:
`docs/zx-format-design.md`). The extension and the magic bytes
(`89 5A 58 0D 0A 1A 0A 00`) only say "zx can read this": every block
names its coder chain, so new codecs come without a new extension. Every
file states the oldest zx release that can read it and the features it
needs, and an older zx refuses cleanly ("needs zx 0.7.0 or later") before
reading any data.

- **Codecs**: LZMA2 (the default for now: the default chain will be
  chosen by benchmarks), LZMA, PPMd (var.H), PPMd8 (var.I), BZip2,
  Deflate, zpaq (context mixing, one zpaq block per zx block) and store,
  after the filters BCJ, ARM, ARMT, ARM64, PPC, SPARC, IA64, RISCV and
  Delta; zstd, LZ4 and LZO1X are read. Experimental codec families
  register in their own id range (`registerZxCodec`): **zcm** (id
  0x10000), context mixing in nine levels from about 0.6 MB/s (level 1)
  to paq8px style models (levels 6 to 8, 12 to 22 KB/s) and level 9 with
  PPMd and an optional LSTM (`-m0=zcm:level=3`, `-m0=zcm:cmix:mem=4g`;
  `lib/src/codec/zcm`, `docs/performance.md`). An archive that uses it
  can only be read by the zx version that wrote it or a later one.
- **Compression settings** (zx switches, not in 7-Zip): `-m0=zcm:auto`
  chooses the zcm level, its memory and the number of workers for this
  machine and this input, and prints the choice before compressing
  (`zcm level 6, 1.2 GiB, 2 threads, estimated 3 min`; `-bb1` adds the
  machine, the budget and the reason). The choice is the strongest level
  whose estimated time fits `-mtime` (`90s`, `10m`, `2h`, `1h30m`, or the
  presets `fast`, `balanced` (the default) and `max`, about 500, 100 and
  10 KB/s of input, and at least 5 s, 30 s and 5 min) within the memory zx may use: `-mmem=SIZE`, or 75% of
  the available memory and at most the available memory less 1.5 GiB
  (the default of `-mmemuse`, whose estimate the choice uses, so the
  memory guard never has to cut its workers). The workers each code one
  block (`-mmt`, `-mbs`, `-mmemuse` bound the choice when given). `-mcal` measures this machine first (a quarter of a
  second) instead of the nominal speeds of `docs/performance.md`.
  `-mtime` or `-mcal` without a method means `-m0=zcm:auto`. With a
  fixed level, `-mmem` is the model memory of each block and
  `-mlstm[=CELLS/LAYERS/HORIZON]` adds the LSTM of level 9 (with auto it
  sizes the LSTM when it is chosen; `-mlstm-` never chooses it). `-mx`
  takes names: with zcm `fast` (2), `normal` (4), `max` (6), `ultra` (8)
  and `cmix` (9, with the LSTM), with the other methods `store` (0),
  `fastest` (1), `fast` (3), `normal` (5), `max` (7), `ultra` (9). The
  archive stores plain settings (`zcm:6:m1024`), so any machine decodes
  it; decompression takes about as long as compression.
- **Blocks** of 16 MiB (`-mbs=4k..64m`), solid by default (`-ms=off`: a
  file per block), coded in parallel by worker isolates (`-mmt`; by
  default as many as half the processors). The workers of a write, an
  extraction or a compaction keep their estimated memory (from the codec
  settings: the LZMA dictionary, the PPMd model, the zpaq method, the zcm
  budget) under `-mmemuse=SIZE` (`4g`, or `p50` for half the RAM), by
  default 75% of the available memory and at most the available memory
  less 1.5 GiB; fewer blocks are coded at once when they would not fit. A damaged block fails only the files that use it; every block
  has a check (`-mcheck=xxh64|crc32c|sha256|blake2sp|none`).
- **Generations**: every `a`, `u`, `d` or `rn` appends a generation in
  place, with its time; the old bytes are never rewritten, and an
  interrupted update is ignored and overwritten by the next one. `l`, `x`,
  `e`, `t` read any generation: `-mversion=3`, `-mversion=2026-09-01`,
  `-mversion="2026-09-01 14:30"` (local time, the last generation up to
  the end of that day or minute). `l -mgenerations` lists them, `l
  -mtimeline=path` lists the versions of one file with the generation
  (and date) that wrote each and the one that replaced or deleted it.
  `a -mcompact[=N] x.zx` (without file names) rewrites the archive with
  the data of the last N generations only (1 by default; blocks used in
  part are repacked); `-mcompact` with an update compacts after it. `l
  -slt` shows `Wasted`, the bytes a compaction frees.
- **Dedup** (on by default, `-mdedup=off`): every file is cut into chunks
  of about 64 KiB where its content says (zpaq's fragmenter,
  `-mchunk=4k..4m`), and a chunk already stored, in this update or in an
  earlier generation, is stored once; a file with the size and SHA-256 of
  a stored one reuses its data at once. Copies, renamed or moved files,
  files sharing parts and data added again later cost almost nothing (a
  second version of a 7 MB source tree added as a new generation: 0.3 MB).
  The archive keeps a table of its chunks for the next updates; it is
  left out of a clear index of an encrypted archive.
- **Hashes**: every file has its SHA-256 (sorted in a lookup table) and a
  TLSH digest (similar files, `ZxArchive.findSimilar`).
- **Encryption**: `-p` (scrypt, AES-256-CTR, HMAC-SHA-256); the names are
  encrypted too unless `-mhe=off`. A wrong password is refused at once.
- **Streamed**: written to a pipe (`zx a -tzx -so x.zx dir | ...`) the
  file has inline records, and `zx x -tzx -si` reads it in one pass.
- **Volumes**: `-v` (repeat it for a list of sizes, the last one
  repeating: `-v4g -v25g`), `-mvdir=DIR[:SIZE|:full]` (destination
  folders in order, each with a budget or until its disk is full),
  `-mvsearch=DIR` (folders where volumes are looked for when reading;
  volumes are recognized by their header, whatever their names). An
  update of a set adds new volumes and leaves the old ones as they are.

```sh
zx a -m0=PPMd8:o=8:mem=256m notes.zx notes/
zx a -mf=ARM64 -m0=LZMA2:d=64m firmware.zx build/
zx a -m0=zcm:level=6 -mmt2 texts.zx texts/
zx a -m0=zcm:auto -mtime=2h -mmem=4g corpus.zx corpus/
zx a -mtime=max -mcal -bb1 notes.zx notes/
zx a -mx=ultra -m0=zcm -mmem=1g logs.zx logs/
zx a -v4g -v25g -mvdir=/mnt/disk1:100g -mvdir=/mnt/disk2:full big.zx data/
zx l -mvsearch=/mnt/disk2 /mnt/disk1/big.zx.001
zx l -mtimeline=docs/plan.txt backup.zx
```

In the library: `ZxArchive.create`, `open(version:, date:,
searchDirs:)`, `add`, `delete`, `rename`, `extract`, `test`, `compact`,
`timeline`, `findBySha256`, `findSimilar`, and `ZxOptions.volumeSizes`,
`volumeDirs` and `compression`: `ZxCompression.auto(timeBudget:, speed:,
memoryBudget:, calibrate:)` or `ZxCompression.manual(zcm: ZcmOptions(...))`
/ `manual(chain: 'BCJ LZMA2:d=64m')`. `ZxArchive.estimate(sources,
options:)` tells, without compressing, what an update would choose and
cost: the zcm level, threads, estimated time and peak memory, a range of
output sizes (from a 64 KiB sample of the input, which also measures this
machine's speed) and warnings (more memory than the machine can spare,
hours of work); its `compression` pins those settings for the update.
`ZxOptions.dedup` and `memoryLimit` give `-mdedup` and `-mmemuse`.
The synchronous building blocks (`ZxWriter`,
`ZxArchiveReader`, `ZxHandler`, `Tlsh`) are exported by `package:zx/zx.dart`.

### Nested archives

Firmware and disk images hold images inside images: a Reolink pak holds a
uImage kernel and UBI images whose volumes are UBIFS file systems, a disk
image holds FAT and ext partitions. By default `zx` behaves as 7-Zip and
opens one level: `zx l firmware.pak` lists the sections. The zx switch
`-snest[N]` (not in 7-Zip) shows the whole thing as one tree for `l`, `t`,
`x` and `e`: every item that is itself an archive or an image becomes a
folder holding its contents, down to N levels (default 4):

```sh
zx l -snest firmware.pak        # loader, fdt/..., kernel/..., rootfs/bin/...
zx x -snest firmware.pak -oout  # out/rootfs/ holds the root file system
zx t -snest disk.img
```

The items of the container formats (pak, uImage, UBI, MBR, GPT) are
always tried; any other item is tried when its first bytes match the
signature of a known format (so an ISO inside a tar opens, a text file
never does). A folder whose archive holds a single archive shows that one
directly (`rootfs/` holds the UBIFS files of the only UBI volume); a
compressed file or a device tree inside a file system (`x.gz`, `x.dtb`)
stays a file. `-t` chains work as before. Symbolic links of firmware file
systems often point up (`../bin/busybox`) or are absolute, which 7-Zip
refuses by default: add `-snld20` to create them.

The library does the same: `ZxArchive.open(path, flatten: true)` lists,
extracts, tests and reads the tree (`ZxItem.nestedFormat` marks the
folders of nested archives), and `archive.openNested(item)` opens one
item as an archive of its own, with `parent` and `nestPath` to go back.
Both are read only; `close()` deletes the temporary copies made for
formats without random access to their items (7z, rar).

Hard links (tar, cpio, SquashFS, UBIFS, ext...) are extracted as hard
links, or as copies where the file system has none.

`ZxArchive` handles zpaq like the other formats (`ZxArchive.create(
'backup.zpaq', sources)`, `add`, `delete`, `rename`, `extract`, `test`,
`readBytes`; `ZxOptions.method` is the zpaq method, `password` encrypts a
new archive). `archive.versions` lists the versions (`ZxVersion`: number,
time, added, deleted, packed size) and `ZxArchive.open(path, version: 2)`
opens the archive as it was after version 2, read only:

```dart
final a = await ZxArchive.open('backup.zpaq');
print('${a.numVersions} versions');
final old = await ZxArchive.open('backup.zpaq', version: 1);
await old.extract('/restore-v1');
```

### Database (zxdb) and `zx sql`

A `.zx` archive can hold a database next to its files (zxdb,
docs/zxdb-design.md): SQL tables in SQLite's dialect, key-value stores,
metadata tables keyed by content (descriptions, tags, subtitles,
screenshots) and read-only system tables over the archive (`zx_files`,
`zx_generations`, `zx_file_history`, `similar()`, `fts_search()`). Every
commit is a generation of the archive, so any table can be read as it was
(`SELECT ... FROM t AS OF '2026-09-01'`). The SQL reference is
docs/zxdb-sql.md.

`zx sql` (a zx extension command) runs SQL on it, like the `sqlite3`
program: statements given on the command line run in order; without them
it reads statements from the standard input, an interactive shell with
line editing and history on a terminal. The output modes and the dot
commands are sqlite3's (`.tables`, `.schema`, `.indexes`, `.mode
list|csv|json|line|table|box|markdown|quote|tabs`, `.headers`, `.import`,
`.export`, `.read`, `.param`, `.timer`...), plus `.asof GEN|DATE` (the
session reads an older generation), `.generations`, `.kv`, `.vacuum
[ultra]`, `.import-arca` / `.export-arca DIR` (arca manifests, subtitles
and previews) and `.import-sqlite` / `.export-sqlite FILE` (SQLite
database files, read and written by a pure Dart implementation of the
SQLite file format):

```sh
zx sql notes.zx "CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)"
zx sql notes.zx "INSERT INTO t (body) VALUES ('first')"
zx sql -table notes.zx "SELECT * FROM t"
zx sql -json backup.zx "SELECT path, size FROM zx_files WHERE size > 1e6"
zx sql backup.zx "SELECT path, distance FROM similar('docs/a.pdf', 20)"
zx sql notes.zx ".export-sqlite notes.db"      # sqlite3 notes.db works
zx sql notes.zx < script.sql                   # a script, errors with lines
zx sql notes.zx                                # the shell (.help)
```

From Dart, `ZxDatabase.open(path)` gives the synchronous API (`db.sql`,
`db.kv(name)`) and `ZxDatabaseAsync.open(path)` the same in a worker
isolate for Flutter apps; `sqliteImport` and `sqliteExport`
(`lib/src/db/sqlite_io/sqlite_io.dart`) move tables between a session
and a SQLite file.

### Signed generations: `zx seal` and `-msign`

A .zx archive can be sealed with NOSTR keys (docs/zx-format.md section
17): each generation is signed by the admin or a maintainer, and anyone,
without the password, sees whether the archive was changed after that.
Keys are given as an nsec, 64 hex digits, `@FILE` (its first line) or,
with an empty value, the environment variable `ZX_NSEC`, so that they are
not on the command line.

```sh
zx a -msign=@admin.nsec book.zx chapters/      # a new archive, sealed: the key is its admin
zx seal -sign=@admin.nsec -add=npub1... book.zx # a maintainer (also -remove=, -rule=admin)
zx u -msign=@maint.nsec book.zx chapters/      # a maintainer's update, signed
zx seal book.zx                                # who signed what (quick check)
zx seal -full book.zx                          # every byte checked, exit code 1 if changed
zx l -slt book.zx                              # the "Seal" property
zx l -mverify=strict book.zx                   # shown as of the last valid seal
zx seal -sign=@admin.nsec -activate old.zx     # seal an archive with a history
zx seal -sign=@admin.nsec -off book.zx         # switch sealing off
```

An update without a key to a sealed archive is written with an unsigned
("pending") seal, until an allowed key signs a later generation; a key
that is neither the admin nor an allowed maintainer is refused. The admin
role is handed over in two steps: the new admin prints its acceptance
(`zx seal -acceptance=@new.nsec book.zx`), the admin writes it
(`zx seal -sign=@admin.nsec -admin=npub1... -accept=HEX book.zx`). A
compaction (`-mcompact`) needs the admin key, as it seals the rewritten
archive again. Volume sets can not be sealed.

### The README of an archive: `zx readme`

An archive describes itself with a `README.md` at its top (and each folder
with its own), as a git repository does; docs/readme.md has the details.
Every image and linked file of it must be an entry of the archive: links to
other places (http, https, mailto) are allowed, images from other places
are never fetched. `zx readme` (a zx extension command, every format)
prints the README, and `-check` reports what can not work (exit code 1):

```sh
zx readme project.zx                 # the README at the top
zx readme project.zip docs           # the README of the folder docs
zx readme -check -all project.zx     # check every README of the archive
```

### Installing

- With the Dart SDK: `dart pub global activate --source path <repo>` puts
  a `zx` command on the PATH (in `~/.pub-cache/bin`, which must be on it).
- Without it: copy a binary from `dist/` (or from a release) into a
  folder on the PATH, as `zx` (`zx.exe` on Windows), and make it
  executable (`chmod +x`).

Native binaries (no Dart SDK needed to run them):

| File | Platform |
|---|---|
| `zx-linux-x64`, `zx-linux-arm64` | Linux |
| `zx-windows-x64.exe`, `zx-windows-arm64.exe` | Windows |
| `zx-macos-arm64`, `zx-macos-x64` | macOS (Apple silicon, Intel) |

The GitHub workflow `.github/workflows/release.yml` builds all six on
native runners and attaches them to the release when a `v*` tag is pushed.
Locally, `tool/build_binaries.sh` writes them to `dist/`: the Dart SDK
cross-compiles only to Linux, so from Linux it builds the two Linux
binaries, plus `zx-windows-x64.exe` when `DART_WINDOWS` points to a
Windows Dart SDK and wine is installed; on a Mac it builds that Mac's
binary. Without a binary, `dart run zx:zx ...` runs the same program from
source.

