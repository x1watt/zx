// Dumps the deterministic test inputs of test/lzma_test_data.dart into a
// directory, so reference outputs can be produced with a C build of the
// LZMA SDK (see test/lzma_test.dart for the golden values).
//
//   dart run tool/lzma_golden.dart <dir>

import 'dart:io';

import '../test/lzma_test_data.dart';

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? '.' : args[0])
    ..createSync(recursive: true);
  goldenInputs().forEach((name, data) {
    File('${dir.path}/$name.bin').writeAsBytesSync(data);
  });
}
