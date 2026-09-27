// The Linux desktop entry of the app (zx.desktop). Pure Dart (no Flutter
// import), so tool/build_deb.sh prints the entry of the package with
// app/tool/desktop_entry.dart from the same list of MIME types that the
// per user integration writes.

import 'formats.dart';

/// The name of the desktop entry.
const kDesktopId = 'zx.desktop';

/// The contents of zx.desktop for the program [executable].
String linuxDesktopEntry(String executable) =>
    '''
[Desktop Entry]
Type=Application
Name=zx
GenericName=Archive Manager
Comment=Open, create and extract archives: zx, 7z, zip, rar, tar, gz, bz2, xz, lzh, arj
Exec=${desktopExec([executable])} %F
Icon=zx
Terminal=false
Categories=Utility;Archiving;Compression;
Keywords=archive;compress;extract;zx;zip;7z;rar;tar;
MimeType=${kArchiveMimeTypes.join(';')};
StartupWMClass=io.github.maxbrito.zx
StartupNotify=true
''';

/// The Exec value of a desktop entry (the quoting rules of the Desktop
/// Entry Specification, then the escaping of string values).
String desktopExec(List<String> args) => args
    .map((a) {
      if (RegExp(r'^[A-Za-z0-9_./+-]+$').hasMatch(a)) return a;
      final q = a.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}');
      return '"$q"'.replaceAll(r'\', r'\\');
    })
    .join(' ');
