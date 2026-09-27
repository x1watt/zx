// Prints the desktop entry (zx.desktop) that starts the given program, or
// with --mime the shared-mime-info definition of application/x-zx.
// Used by tool/build_deb.sh: dart tool/desktop_entry.dart /usr/bin/zx-gui

import 'dart:io';

import 'package:zx_app/src/desktop_entry.dart';
import 'package:zx_app/src/formats.dart' show kZxMimeXml;

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/desktop_entry.dart <executable>|--mime');
    exit(2);
  }
  if (args.single == '--mime') {
    stdout.write(kZxMimeXml);
    return;
  }
  stdout.write(linuxDesktopEntry(args.single));
}
