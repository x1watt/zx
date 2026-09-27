// Small text and icon helpers of the views.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

String formatBytes(int? n, {bool exact = false}) {
  if (n == null) return '';
  if (exact) return '${_group(n)} bytes';
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  if (n < 1024) return n == 1 ? '1 byte' : '$n bytes';
  var v = n.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0)} ${units[u]}';
}

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String two(int v) => v.toString().padLeft(2, '0');

String formatDate(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

String formatCrc(int? crc) =>
    crc == null ? '' : crc.toRadixString(16).toUpperCase().padLeft(8, '0');

String formatRatio(double? r) =>
    r == null ? '' : '${(r * 100).round().clamp(0, 999)}%';

/// The extension of [name] in lower case, without the dot.
String extensionOf(String name) {
  final k = name.lastIndexOf('.');
  return k <= 0 ? '' : name.substring(k + 1).toLowerCase();
}

const _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico', 'wbmp'};
const _textExt = {
  'txt',
  'md',
  'markdown',
  'rst',
  'log',
  'csv',
  'tsv',
  'json',
  'xml',
  'yaml',
  'yml',
  'toml',
  'ini',
  'cfg',
  'conf',
  'html',
  'htm',
  'css',
  'js',
  'ts',
  'dart',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'java',
  'kt',
  'py',
  'rb',
  'go',
  'rs',
  'sh',
  'bat',
  'ps1',
  'sql',
  'svg',
  'properties',
  'gradle',
  'cmake',
  'mk',
  'makefile',
  'license',
  'readme',
  'diff',
  'patch',
  'swift',
  'm',
  'pl',
  'lua',
};

bool isImageName(String name) => _imageExt.contains(extensionOf(name));

bool isTextName(String name) {
  final e = extensionOf(name);
  if (_textExt.contains(e)) return true;
  final n = name.toLowerCase();
  return e.isEmpty &&
      (n == 'readme' || n == 'license' || n == 'makefile' || n == 'copying');
}

/// The icon and its color for a row.
(IconData, Color) iconFor(ZxItem item, ColorScheme cs) {
  if (item.isDir) return (Icons.folder_rounded, const Color(0xFFE0A526));
  if (item.isSymlink) return (Icons.link_rounded, cs.tertiary);
  final e = extensionOf(item.name);
  switch (e) {
    case 'png' ||
        'jpg' ||
        'jpeg' ||
        'gif' ||
        'bmp' ||
        'webp' ||
        'svg' ||
        'ico' ||
        'tif' ||
        'tiff' ||
        'heic':
      return (Icons.image_outlined, const Color(0xFF2E9D6A));
    case 'mp3' || 'wav' || 'flac' || 'ogg' || 'opus' || 'm4a' || 'aac':
      return (Icons.audio_file_outlined, const Color(0xFF9C4DCC));
    case 'mp4' || 'mkv' || 'avi' || 'mov' || 'webm' || 'wmv':
      return (Icons.video_file_outlined, const Color(0xFFD1453B));
    case 'pdf':
      return (Icons.picture_as_pdf_outlined, const Color(0xFFD1453B));
    case '7z' ||
        'zip' ||
        'rar' ||
        'tar' ||
        'gz' ||
        'tgz' ||
        'bz2' ||
        'xz' ||
        'lzma' ||
        'lzh' ||
        'lha' ||
        'arj' ||
        'zpaq' ||
        'jar' ||
        'apk' ||
        'deb' ||
        'rpm' ||
        'zst':
      return (Icons.folder_zip_outlined, const Color(0xFF8D6E63));
    case 'exe' || 'msi' || 'bin' || 'so' || 'dll' || 'dylib' || 'appimage':
      return (Icons.memory_outlined, cs.onSurfaceVariant);
    case 'sh' || 'bat' || 'cmd' || 'ps1':
      return (Icons.terminal_outlined, cs.onSurfaceVariant);
    case 'doc' || 'docx' || 'odt' || 'rtf':
      return (Icons.article_outlined, const Color(0xFF2B6CC4));
    case 'xls' || 'xlsx' || 'ods' || 'csv' || 'tsv':
      return (Icons.table_chart_outlined, const Color(0xFF2E9D6A));
    case 'ppt' || 'pptx' || 'odp':
      return (Icons.slideshow_outlined, const Color(0xFFE07A26));
    case 'html' ||
        'htm' ||
        'css' ||
        'js' ||
        'ts' ||
        'dart' ||
        'c' ||
        'h' ||
        'cc' ||
        'cpp' ||
        'hpp' ||
        'java' ||
        'kt' ||
        'py' ||
        'rb' ||
        'go' ||
        'rs' ||
        'json' ||
        'xml' ||
        'yaml' ||
        'yml' ||
        'toml' ||
        'swift':
      return (Icons.code_rounded, const Color(0xFF3F7FBF));
    case 'txt' || 'md' || 'log' || 'ini' || 'cfg' || 'conf' || 'rst':
      return (Icons.description_outlined, cs.onSurfaceVariant);
    case 'ttf' || 'otf' || 'woff' || 'woff2':
      return (Icons.font_download_outlined, cs.onSurfaceVariant);
  }
  return (Icons.insert_drive_file_outlined, cs.onSurfaceVariant);
}

/// A readable text for an error of the library.
String errorText(Object e) {
  if (e is SevenZipException) {
    final m = e.message;
    switch (e.kind) {
      case SevenZipError.isNotArc:
        return 'This file is not an archive of a supported format.';
      case SevenZipError.wrongPassword:
        return 'Wrong password.';
      case SevenZipError.cancelled:
        return 'Cancelled.';
      default:
        return m.isEmpty ? e.kind.name : m;
    }
  }
  if (e is FileSystemException) {
    final os = e.osError?.message;
    return [e.message, ?e.path, ?os].where((s) => s.isNotEmpty).join(': ');
  }
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

String itemErrorText(ZxItemError e) {
  final what = switch (e.kind) {
    SevenZipError.wrongPassword => 'wrong password',
    SevenZipError.crc => 'CRC error',
    SevenZipError.data => 'data error',
    SevenZipError.unsupportedMethod => 'unsupported method',
    SevenZipError.unavailable => 'data not available',
    SevenZipError.unexpectedEnd => 'unexpected end of data',
    SevenZipError.dataAfterEnd => 'data after the end',
    SevenZipError.headers => 'headers error',
    SevenZipError.io => 'input or output error',
    SevenZipError.cancelled => 'cancelled',
    SevenZipError.unsupported => 'not supported',
    SevenZipError.isNotArc => 'not an archive',
  };
  return e.message == null || e.message!.isEmpty ? what : '$what: ${e.message}';
}
