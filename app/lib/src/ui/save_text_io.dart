import 'dart:io';
import 'dart:typed_data';

/// Writes [text] to the file [path].
Future<void> saveText(String path, String text) =>
    File(path).writeAsString(text);

/// Writes [bytes] to the file [path].
Future<void> saveBytes(String path, Uint8List bytes) =>
    File(path).writeAsBytes(bytes);
