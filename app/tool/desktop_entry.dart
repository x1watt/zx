// Prints the desktop entry (zx.desktop) that starts the given program.
// Used by tool/build_deb.sh: dart tool/desktop_entry.dart /usr/bin/zx-gui

import 'dart:io';

import 'package:zx_app/src/desktop_entry.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/desktop_entry.dart <executable>');
    exit(2);
  }
  stdout.write(linuxDesktopEntry(args.single));
}
