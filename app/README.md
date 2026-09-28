# zx (desktop app)

An archive manager in the style of WinZip and the 7-Zip File Manager,
written with Flutter on the `ZxArchive` API of the `zx` package (the
parent folder). It reads every format of the `zx` command line tool (7z,
zip and jar, rar 1.5 to 7, tar, tar.gz / tgz, tar.bz2, tar.xz, tar.lzma,
gz, bz2, xz, lzma, lzh, arj, zpaq, split volumes, cpio, ISO, UDF,
SquashFS, cramfs, JFFS2, ext, FAT, MBR and GPT disk images, and firmware:
Reolink pak, uImage, UBI, UBIFS, device trees) and writes zx, 7z, zip,
RAR5, tar and the compressed tars, lzh, arj, zpaq, gz, bz2 and xz.

Every archive operation runs in a background isolate of `ZxArchive`; the
UI isolate only sends requests, draws the throttled progress and answers
the questions of the operation (password, overwrite). The app has no
native code of its own besides the runners and uses three small packages:
`file_selector` (file dialogs), `desktop_drop` (drag and drop) and `path`.

## Using it

- **Open**: `zx_app archive.7z`, File > Open (Ctrl+O), drop an archive on
  the window, or pick one of the recent archives.
- **Browse**: the folder tree on the left, the file list on the right
  (click a column to sort, again to reverse), the path bar with Back
  (Alt+Left), Forward (Alt+Right) and Up (Backspace, Alt+Up), the filter
  box (Ctrl+F) for the current folder. Double click or Enter enters a
  folder or opens a file with its default program (the file is extracted
  to a temporary folder first). Ctrl and Shift click select several
  items, Ctrl+A all of them, the arrow keys, Page Up/Down, Home and End
  move the selection. A right click opens the context menu (Open, Extract
  to..., Extract here, Copy path, Rename, Delete, Properties).
- **Archives in archives**: double click, Enter or "Open as archive"
  (context menu) on a file that is itself an archive opens it as a new
  level: a zip in a tar, an ISO, the sections of a firmware file (pak,
  uImage, UBI), the partitions of a disk image (MBR, GPT, FAT, ext),
  SquashFS and the other file system images. A level that holds a single
  archive shows that one (a firmware's `rootfs` shows the files of its
  UBIFS volume). The path bar shows the chain (`firmware.pak > rootfs >
  etc > init.d`) with a mark and an image icon where a nested archive
  starts, and so does the title bar; Back and Up at the top of a nested
  level go back to its parent, at the item. Nested levels are read-only;
  extract, test, the preview and "Open with default program" work in
  them. A file that is no archive (and documents such as docx or epub)
  opens with its program. View, **Show inner filesystems** (saved) opens
  archives with every nested archive shown as a folder, read-only.
- **Versions** (zpaq): the status bar shows "Version N of M"; click it
  (or Archive, Show version) to list the versions with their dates and
  open an older one, read-only.
- **Data** (.zx archives with a database, zxdb): a Files | Data switch
  appears above the view. The Data view lists the tables, views, KV
  stores, time series and the system tables (zx_files, zx_generations,
  zx_file_history, zx_meta, zx_layers, zx_media, zx_fingerprints) in
  groups; a table opens in a browser with pages of 100 rows and sorting
  by a click on a column (DATETIME columns are shown as dates). "SQL
  query" runs any SQL (Ctrl+Enter), shows the rows or the error, and
  CSV or JSON export saves the rows (a whole table from the browser).
  Archive, **New database** creates one in a .zx archive that has none.
  Writes are refused in read-only views (a nested archive, the inner
  filesystems view, an older version, which reads the database as of
  that generation). The metadata of a file (title, description, tags,
  subtitles and other layers with their language, screenshots) is shown
  above its preview and in its Properties. **Find similar files**
  (context menu, Archive menu) lists the 20 nearest files by TLSH
  distance, **Find by SHA-256** the files with that content; a click
  shows the file in the list. The queries run in the database's worker
  isolate (`ZxDatabaseAsync`), never on the UI isolate.
- **Extract** (Ctrl+E): destination (default: a folder named after the
  archive, next to it), all files or the selection (relative to the
  current folder), keep paths or not, what to do with existing files
  (ask for each one, overwrite, skip, rename), open the folder afterwards.
- **Add**: the Add button or files dropped on the window add into the
  current folder of the archive, with level, method, password (zip:
  AES-256 or ZipCrypto) and solid where the format has them.
- **New archive** (Ctrl+N): name, format (zx, 7z, zip, tar.gz, tar.bz2,
  tar.xz, rar, tar, lzh, arj, zpaq with its methods 0 to 5, and gz, bz2,
  xz for one file), files and folders,
  settings; a password with encrypted names for zx, 7z and rar.
- **Compression** (new .zx archives and additions to one): **Auto** (the
  default) lets zx choose the zcm level, its memory and the threads for
  this machine and the files, within a time budget: Fast, Balanced, Max,
  or Custom (a number of minutes). The dialog shows what it chose, for
  example "Chosen: level 6, 1.2 GiB RAM, 2 threads, ~3 minutes", with the
  expected output size; the estimate (`ZxArchive.estimate`) runs in the
  background, about half a second after the last change, and the update
  uses exactly the settings shown. **Manual**: the method (zcm levels 1
  to 9: fastest, fast, normal, max, ultra, cmix; LZMA2, PPMd8, PPMd,
  BZip2, Deflate, zpaq, store), the level of the other methods, and for
  zcm the memory per stream (with the safe maximum of this machine), the
  LSTM of level 9 and its size, and the threads. Choices that need more
  memory than the machine can spare, or hours of work ("about 30 hours at
  ~0.5 KB/s"), are shown as warnings. **Deduplicate identical data** (on
  by default) stores identical files and parts of files once. zcm is experimental: only this zx
  version and later read it.
- **Delete** (Del), **Rename** (F2), **New folder**, **Test**, **Info**
  (archive properties, comment of zip and RAR5 archives, the nesting
  chain, the details of a container such as the MTD table of a pak),
  **Properties** of items (Alt+Enter).
- Actions a format does not allow (adding to a .xz file, changing a RAR 4
  or a multi-volume archive...) are disabled, with a tooltip that says why.
- **Progress**: percent, bytes, the speed of the last 20 seconds, the
  elapsed time and the time left ("about 12 min left"), Cancel.
- **Settings**: theme (system, light, dark), preview pane, default format
  and level of new archives, the compression defaults of .zx (Auto with
  its time budget, or Manual with the method, memory, threads and LSTM;
  deduplication),
  delete confirmation, open the folder after extracting, and the desktop
  integration.

## Command line

```
zx_app [archive]
zx_app --extract-to-folder <archive>...
zx_app --install-integration [--register | --associations] [--context-menu]
zx_app --remove-integration [--associations] [--context-menu]
zx_app --integration-status
```

`--extract-to-folder` extracts each archive into a new folder named after
it (without the archive extensions: `a.tar.gz` and `a.tgz` give `a`,
`a.7z.001` and `a.part1.rar` give `a`, `a.txt.gz` gives `a.txt`), next to
it; when that name exists, `a (2)`, `a (3)`... It shows a small window
with the progress (and a password question when needed) and closes itself
when every archive was extracted; with errors it stays open with the
list.

`--install-integration` without a part installs both parts;
`--remove-integration` without a part removes everything, the desktop
entry and the icons too.

## Desktop integration

### Linux

`tool/install_linux.sh` (at the root of the repository) builds the
release bundle (through `~/bin/android-build-locked` when it exists),
copies it to `~/.local/share/zx/app`, writes the launcher
`~/.local/bin/zx-gui` and runs `zx_app --install-integration`. Nothing
needs root. `tool/uninstall_linux.sh` removes it all again.

The two switches of Settings run the same code (`lib/src/integration.dart`):

- **Associate archive file types with zx**: the desktop entry
  `~/.local/share/applications/zx.desktop` lists the archive MIME types of
  shared-mime-info (`application/x-7z-compressed`, `application/zip`,
  `application/vnd.rar`, `application/x-compressed-tar`,
  `application/gzip`, `application/x-xz`, `application/x-lha`,
  `application/x-arj`, `application/x-zpaq` and the others, with their aliases); switching on
  makes zx the default application of each in `~/.config/mimeapps.list`
  (and in the desktop specific `*-mimeapps.list` files that exist), after
  saving the previous defaults in `~/.config/zx/previous-defaults.json`;
  switching off gives them back. A copy of each file is kept as
  `*.zx-backup` before its first change.
- **Add "Extract to folder" to the file manager right-click menu**:
  - Nautilus script `~/.local/share/nautilus/scripts/Extract to folder (zx)`
    (right click, Scripts).
  - nautilus-python extension
    `~/.local/share/nautilus-python/extensions/zx_extract.py`: a top level
    `Extract to "name/"` item on archives. It is loaded only when the
    Python bindings of Nautilus are installed
    (`sudo apt install python3-nautilus`) and Nautilus was restarted
    (`nautilus -q`).
  - Thunar custom action in `~/.config/Thunar/uca.xml` (merged: the other
    actions stay; when the file does not exist the system actions of
    `/etc/xdg/Thunar/uca.xml` are copied first).

### Windows (per user, no administrator rights)

The same switches write under `HKCU\Software\Classes` with `reg.exe`:

- ProgID `zx.archive` with `DefaultIcon`, `shell\open\command`
  (`"zx_app.exe" "%1"`) and the verb `shell\zx.extract` ("Extract to folder
  (zx)", `"zx_app.exe" --extract-to-folder "%1"`);
  `Applications\zx_app.exe\SupportedTypes`, and `.ext\OpenWithProgids`
  for each archive extension so zx is offered in "Open with".
- Associations on: the default value of `HKCU\Software\Classes\.7z`,
  `.zip`, `.rar`... becomes `zx.archive`. Windows 10 and 11 keep a choice
  the user made in "Open with, Always" (the protected `UserChoice` key),
  which no program may set: then choose zx there once.
- Context menu on: `SystemFileAssociations\.ext\shell\zx.extract`, so the
  verb shows on every archive whatever program opens it (on Windows 11
  under "Show more options").

### macOS

- File types: `macos/Runner/Info.plist` declares `CFBundleDocumentTypes`
  for the archive UTIs (`org.7-zip.7-zip-archive`, `public.zip-archive`,
  `com.rarlab.rar-archive`, `public.tar-archive`,
  `org.gnu.gnu-zip-archive`, `public.bzip2-archive`,
  `org.tukaani.xz-archive`...) with the rank `Alternate`, so zx appears
  in "Open With"; to make it the default, use Finder's Get Info, "Open
  with", "Change All". Finder sends the files as Apple events:
  `AppDelegate.application(_:openFiles:)` passes them to Dart through the
  `zx/files` channel.
- "Extract to folder": a Quick Action. In Automator: New, Quick Action,
  "Workflow receives current files or folders in Finder", add "Run Shell
  Script" with "Pass input: as arguments" and

  ```sh
  /Applications/zx.app/Contents/MacOS/zx --extract-to-folder "$@"
  ```

  and save it as "Extract to folder (zx)"; it appears in the right-click
  menu under Quick Actions.
- The settings switches are not available on macOS (they say so).

The Windows and macOS parts are written but were not run on those
systems.

## Development

```sh
flutter pub get
flutter analyze
flutter test                              # unit and widget tests
flutter test integration_test -d linux    # the real app, real archives
flutter run -d linux
```

On the development machine the Linux builds (`flutter build`, `flutter
run`, `flutter test integration_test`) go through
`~/bin/android-build-locked`.

- `lib/main.dart`: the command line modes.
- `lib/src/app.dart`: themes and the two windows.
- `lib/src/archive_model.dart`: folder, history, sort, filter, selection.
- `lib/src/ui/`: the browser page and its panels, the file list, the
  preview, the settings page, the "Extract to folder" window.
- `lib/src/dialogs/`: extract, add, new archive (with the .zx
  Compression section of `zx_compression.dart`), password, overwrite,
  progress, properties, errors.
- `lib/src/integration.dart`: the desktop integration (Linux, Windows).
- `lib/src/services.dart`: the launcher and the file dialogs, replaced by
  fakes in the tests (`test/helpers.dart`), which also point every path
  at a temporary folder so the tests never touch the real desktop.
- `assets/icon/`: the icon (`zx.svg` and PNG sizes).
