# Mounting an archive as a virtual drive (`zx mount`)

Linux, FUSE 3. Any archive zx opens can be mounted; the ones zx can update
(.zx, 7z, zip, tar...) can be changed through the mount. Several archives
can be mounted at the same time, each with its own mount point.

```
zx mount ~/backup.zx ~/drive            # in the background
ls ~/drive; cp report.pdf ~/drive/docs/
zx umount ~/drive                       # writes pending changes first
zx mounts                               # what is mounted
```

## How it works

Each mount is two processes, started by `zx mount`:

- `zx mount -f` (Dart): the archive, the file system model `ZxFs`
  (`lib/src/mount/zx_fs.dart`) and the bridge (`fuse_bridge.dart`).
- `zx-mount` (C, `native/fuse/zx-mount.c`, libfuse 3): talks to the kernel
  and forwards every request over a pipe. It has no archive logic, so the
  library stays pure Dart (no FFI) and the protocol is the only coupling.

**Reading.** A file of 8 MiB or more is read in chunks of 4 MiB with
`ZxArchive.readRange`, which decodes only the blocks that hold the chunk
(.zx, zip, tar, disk images and file systems have random access), so
`head` or a video player starts at once; the next chunk is fetched while a
sequential reader consumes the current one, and 64 MiB of chunks are kept.
Smaller files, and big files of formats with no random access (solid 7z,
compressed tars), are extracted whole once into the cache folder
(`~/.cache/zx/mount/PID-NAME`), then read by offset; that cache keeps up to
`-cache=SIZE` (default 1g), least recently used out first. The first read
of such a big file waits for its extraction.

**Writing.** A changed or new file lives in the same folder (staging).
Deletes, renames and new folders are noted in a journal. Nothing touches
the archive until a *commit*, which replays the journal and then adds all
staged files in one update (one new generation for .zx). A commit happens
after `-commit=SECONDS` (default 5) with no write and no writer open, on
`fsync` and on unmount. A crash loses the changes since the last commit
and never damages the archive; if a commit fails at unmount the staged
files are kept in the cache folder and named in the message.

An archive that can not be changed (rar, iso, a nested or `-version=N`
view) is mounted read only.

Not supported: hard links, symbolic links creation, extended attributes,
`chmod`/`chown`/`utimens` (accepted and ignored: zx does not store them
through the mount), rename flags (`RENAME_EXCHANGE`).

## Options

See `zx mount -help`. Passwords: `-pfile=FILE` (mode 0600 required) or
`-pcmd=COMMAND` (for example `secret-tool lookup zx backup`). `-pPASSWORD`
works but is visible in `ps`.

## Drives at login or boot (per-user systemd)

```
zx mounts add backup ~/backup.zx ~/drive -pfile=~/.config/zx/backup.pw
zx mounts enable-boot            # installs the user unit, starts the drives
zx mounts enable-boot -linger    # also: start at boot, before you log in
zx mounts disable-boot           # removes the unit
```

`~/.config/zx/mounts.conf` is the table (INI, one `[name]` section per
drive: `archive`, `mountpoint`, `readonly`, `allow_other`, `version`,
`password_file`, `password_cmd`, `commit`, `cache`). `zx mount -persist`
adds a drive to it as it mounts. The unit `zx-mount@NAME.service`
(`~/.config/systemd/user`) runs `zx mount -f -entry=NAME`; stopping it
(SIGTERM) unmounts and commits; a failure restarts it after 10 seconds,
and a missing archive or a wrong password is logged to the journal
(`journalctl --user -u zx-mount@NAME`) and never blocks the session.
Without a password file or command an encrypted archive can not start
unattended.

## Building the daemon

`make -C native/fuse` (libfuse3 headers from `libfuse3-dev`, or
`tool/fetch_fuse_headers.sh` puts them in `ref/build-deps` without root).
`zx` looks for `zx-mount` in `$ZX_MOUNT_BIN`, next to the program,
`native/fuse` of the source tree, `~/.local/lib/zx`, `/usr/lib/zx`,
`/usr/libexec/zx` and `/opt/zx`. The .deb installs it in `/usr/lib/zx`.

## Protocol (zx-mount.c and fuse_bridge.dart)

Little endian frames. Request: `u32 length`, `u8 op`, arguments. Response:
`u32 length`, `i32 status` (0 or minus an errno), result. Strings are
`u32 length` and bytes. Ops: getattr, readdir, open, create, read, write,
release, unlink, rmdir, mkdir, rename, truncate, fsync, readlink, statfs,
destroy (unmount: commit, then the daemon exits). The daemon is single
threaded, so requests are answered in order.

## Other systems

The model (`ZxFs`) has no FUSE in it: macFUSE or FUSE-T on macOS and
WinFsp on Windows need only another daemon speaking the same protocol.
