// ignore_for_file: file_names

// The 7zr command line program (Dart port of the LZMA SDK console).

import 'dart:io';

import 'package:zx/src/cli/main.dart';
import 'package:zx/src/cli/std_stream.dart';

void main(List<String> args) {
  exitCode = runSevenZipCliSync(args, processCliIo());
}
