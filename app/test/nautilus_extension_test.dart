// The native Nautilus extension (native/nautilus/zx-nautilus.c) keeps its
// own copy of the archive extensions and MIME types: they must be the ones
// of formats.dart. (The extension itself is tested by its harness:
// make -C native/nautilus test.)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zx_app/src/formats.dart';

/// The strings of the C array [name] in [source].
List<String> cArray(String source, String name) {
  final m = RegExp(
    'static const char \\*const $name\\[\\] = \\{([\\s\\S]*?)\\};',
  ).firstMatch(source);
  expect(m, isNotNull, reason: 'array $name');
  return [
    for (final s in RegExp(r'"([^"]*)"').allMatches(m!.group(1)!)) s.group(1)!,
  ];
}

void main() {
  final source = File('../native/nautilus/zx-nautilus.c').readAsStringSync();

  test('the extensions are those of kArchiveExtensions', () {
    expect(cArray(source, 'zx_extensions'), kArchiveExtensions);
  });

  test('the MIME types are those of kArchiveMimeTypes', () {
    expect(cArray(source, 'zx_mime_types'), kArchiveMimeTypes);
  });

  test('the switch file is the one the settings write', () {
    expect(source, contains('"zx", "context-menu-disabled"'));
  });
}
