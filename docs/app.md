# The zx desktop app


`app/` is **zx**, a WinZip / 7-Zip File Manager style archive manager for
Linux, Windows and macOS, written with Flutter on the `ZxArchive` API (so
every format of the command line tool, and all the archive work in
background isolates: the window never freezes).

- Open archives from the command line, File > Open, drag and drop, or the
  recent list; browse with a folder tree, a breadcrumb path bar (Back,
  Forward, Up), a sortable file list (Name, Size, Packed, Ratio, Modified,
  Method, Encrypted, CRC), multi selection, a quick filter and a preview
  of text and images.
- Extract (all or the selection, with or without paths, overwrite policy
  with a per file question: Yes, No, Yes to all, No to all, Keep both,
  Cancel), extract here, test, open a file with its default program.
- Add files and folders (dialog or drag and drop, into the current folder
  of the archive) with level, method, password, encrypted names and solid;
  delete, rename, new folder, archive comment (zip, RAR5); new archives in
  7z, zip, tar.gz, tar.bz2, tar.xz, rar (RAR5), tar, lzh, arj, zpaq, gz,
  bz2, xz.
- Passwords are asked when needed (show / hide, wrong password retry);
  long operations show percent, current file, speed and Cancel. Actions a
  format does not allow are disabled with a tooltip saying why.
- The README of the current folder of an archive (docs/readme.md) is
  shown below its items, rendered; markdown files are rendered in the
  preview. Its images come from the archive only, a link into the
  archive opens the folder or selects the file, a link to another place
  asks before it opens the browser.
- A sealed .zx archive (signed generations) shows its state in the
  status bar (Sealed, Not signed, Seal broken); a click lists who signed
  each version and runs the full check. The version list marks each
  version, and the README panel names the admin.
- Settings: theme (system, light, dark), default format and level,
  confirmations, the README panel, and the desktop integration switches
  below.

### The web version

https://x1watt.github.io/zx/online/ is the app in the browser, read only:
browse, preview, READMEs, seals, test, the Data view of a .zx database
(read-only SQL) and Download of selected files. Archives are opened

- from this computer (Open files, or drop them on the page): the page
  reads them where they are, in blocks, nothing is uploaded; Keep in
  library copies one into the browser's storage;
- from an address (Open address, or `online/?url=ADDRESS` as a link):
  when the server answers range requests to other sites (CORS), only the
  parts the archive needs are fetched, so listing a large archive reads
  its start and its end; when it sends only whole files, the app offers
  to download the archive into the library; when it does not allow other
  sites at all (GitHub release downloads, for one), the app says so;
- from the library (the sidebar), which stays in this browser.

Links open archives: paste the archive's address after the page's,

    https://x1watt.github.io/zx/online/https://x1watt.github.io/zx/examples/zx-demo.zx

and add `#path=PATH` to open it at the folder PATH, or with the file PATH
selected and previewed (a README.md is shown rendered), and `#theme=NAME`
(`dark`, `light`, `green`, `orange`) to show it in that theme:

    https://x1watt.github.io/zx/online/https://x1watt.github.io/zx/examples/zx-demo.zx#path=docs/zx-format.md&theme=green

The options go after `#`, so the archive's own address keeps its query
string (`?token=...`). The older form `online/?url=ADDRESS&path=PATH`
works too. While an archive from an address is shown, the browser's
address bar holds the link of the current folder or selected file, and
Share link copies it (with the current theme, unless unticked). The
archive must be served as described above (CORS, and ranges to read it in
place).

Themes: dark, light, and two retro ones, green and orange phosphor on
black with a terminal font, from the palette icon at the top right. The
browser remembers the choice; a link's theme applies to that visit only.

It needs WebAssembly with garbage collection and module workers (Chrome
and Edge 119, Firefox 120, Safari 18.2 or newer). Writing archives,
extracting to folders and nested archives that need a temporary copy (an
archive inside a 7z or rar) are for the desktop app. How it works:
docs/architecture.md section 20.

### Installing on Linux

The normal install is the Debian package (Ubuntu, Debian and their
derivatives, amd64):

```sh
tool/build_deb.sh                        # writes dist/zx_<version>_amd64.deb
sudo apt install ./dist/zx_0.5.0_amd64.deb
nautilus -q                              # once, so Nautilus loads the extension
```

| What | Where |
|---|---|
| The release bundle | `/opt/zx` (`zx-gui`) |
| Launcher, command line tool | `/usr/bin/zx-gui`, `/usr/bin/zx` |
| Desktop entry with the archive MIME types | `/usr/share/applications/zx.desktop` |
| Icon (SVG and PNG sizes) | `/usr/share/icons/hicolor/*/apps/zx.*` |
| The MIME type of .zx files (`application/x-zx`, magic and `*.zx`) | `/usr/share/mime/packages/zx-archive.xml` |
| Nautilus: top level `Extract to "name/"` item on archives | `/usr/lib/x86_64-linux-gnu/nautilus/extensions-4/libzx-nautilus.so` |
| Documentation, license | `/usr/share/doc/zx` |

The package needs nothing beyond the libraries of a GTK desktop: the
Nautilus item is a native extension (C, `native/nautilus/`), not a
nautilus-python script, so no other package has to be installed. The
package does not change anyone's default applications: each user turns
that on in Settings. The Nautilus item is on unless a user switches it
off in Settings (then `~/.config/zx/context-menu-disabled` exists and the
extension shows nothing; no restart needed). `sudo apt remove zx`
removes it all; the per user files (settings, `mimeapps.list` lines,
Thunar action) stay until switched off in Settings before removing.

Without root, a per user install:

```sh
tool/install_linux.sh            # build, install, associate, add the menu
tool/install_linux.sh --no-associations --no-context-menu
tool/uninstall_linux.sh [--purge]
```

| What | Where |
|---|---|
| The release bundle | `~/.local/share/zx/app` (`zx-gui`) |
| Launcher | `~/.local/bin/zx-gui` |
| Desktop entry with the archive MIME types | `~/.local/share/applications/zx.desktop` |
| Icon (SVG and PNG sizes) | `~/.local/share/icons/hicolor/*/apps/zx.*` |
| The MIME type of .zx files | `~/.local/share/mime/packages/zx-archive.xml` |
| Default application (when associated) | `~/.config/mimeapps.list` (the previous defaults are restored when switched off) |
| Nautilus: "Extract to folder (zx)" under Scripts | `~/.local/share/nautilus/scripts/` |
| Thunar custom action (merged, other actions kept) | `~/.config/Thunar/uca.xml` |

A per user install can not add a top level Nautilus item (Nautilus
loads extensions only from the system folder), so there it is under
Scripts in the right-click menu.

The two switches of Settings (associate archive types, "Extract to
folder" in the file manager) install and remove the per user files: the
Thunar action and, for a per user install, the Nautilus script; with the
package the menu switch turns its Nautilus extension on and off. The
switches and the script call the same code, also reachable as
`zx-gui --install-integration [--associations] [--context-menu]`,
`zx-gui --remove-integration [...]` and `zx-gui --integration-status`.
`zx-gui --extract-to-folder a.zip b.tar.gz` extracts each archive into a
new folder named after it next to it (`b.tar.gz` gives `b/`, an existing
name gives `b (2)/`), in a small progress window that asks for a password
when needed and closes itself; this is what the menu entries run.

Windows (per user, `HKCU\Software\Classes`, no administrator rights) and
macOS (document types in `Info.plist`, a Finder Quick Action) are
described in `app/README.md`.

