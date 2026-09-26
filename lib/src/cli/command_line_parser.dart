// Command line parsing: Common/CommandLineParser.cpp (CParser, the switch
// forms) and Common/ListFileUtils.cpp (ReadNamesFromListFile2) of the LZMA
// SDK.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'platform.dart';

/// NSwitchType.
enum SwitchType { simple, minus, string, char }

/// CSwitchForm.
class SwitchForm {
  final String key;
  final SwitchType type;
  final bool multi;
  final int minLen;
  final String? postCharSet;
  const SwitchForm(this.key, this.type,
      [this.multi = false, this.minLen = 0, this.postCharSet]);
}

/// CSwitchResult.
class SwitchResult {
  bool thereIs = false;
  bool withMinus = false;
  int postCharIndex = -1;
  final List<String> postStrings = [];
}

// IsString1PrefixedByString2_NoCase_Ascii
bool _isPrefixedNoCaseAscii(String s, int pos, String key) {
  if (pos + key.length > s.length) return false;
  for (var i = 0; i < key.length; i++) {
    var c = s.codeUnitAt(pos + i);
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    var k = key.codeUnitAt(i);
    if (k >= 0x41 && k <= 0x5A) k += 0x20;
    if (c != k) return false;
  }
  return true;
}

const String _kStopSwitchParsing = '--';

/// CParser.
class CommandLineParser {
  List<SwitchResult> _switches = [];
  final List<String> nonSwitchStrings = [];

  /// NonSwitchStrings[stopSwitchIndex..] are after "--".
  int stopSwitchIndex = -1;
  String errorMessage = '';
  String errorLine = '';

  SwitchResult operator [](int index) => _switches[index];

  // IsItSwitchChar
  static bool _isItSwitchChar(int c) => c == 0x2D; // '-'

  // CParser::ParseString
  bool _parseString(String s, List<SwitchForm> switchForms) {
    if (s.isEmpty || !_isItSwitchChar(s.codeUnitAt(0))) return false;

    var pos = 1;
    var switchIndex = 0;
    var maxLen = -1;

    for (var i = 0; i < switchForms.length; i++) {
      final key = switchForms[i].key;
      final switchLen = key.length;
      if (switchLen <= maxLen || pos + switchLen > s.length) continue;
      if (_isPrefixedNoCaseAscii(s, pos, key)) {
        switchIndex = i;
        maxLen = switchLen;
      }
    }

    if (maxLen < 0) {
      errorMessage = 'Unknown switch:';
      return false;
    }

    pos += maxLen;

    final sw = _switches[switchIndex];
    final form = switchForms[switchIndex];

    if (!form.multi && sw.thereIs) {
      errorMessage = 'Multiple instances for switch:';
      return false;
    }

    sw.thereIs = true;

    final rem = s.length - pos;
    if (rem < form.minLen) {
      errorMessage = 'Too short switch:';
      return false;
    }

    sw.withMinus = false;
    sw.postCharIndex = -1;

    switch (form.type) {
      case SwitchType.minus:
        if (rem == 1) {
          sw.withMinus = s[pos] == '-';
          if (sw.withMinus) return true;
          errorMessage = 'Incorrect switch postfix:';
          return false;
        }
      case SwitchType.char:
        if (rem == 1) {
          final c = s.codeUnitAt(pos);
          if (c <= 0x7F) {
            sw.postCharIndex = form.postCharSet!.indexOf(String.fromCharCode(c));
            if (sw.postCharIndex >= 0) return true;
          }
          errorMessage = 'Incorrect switch postfix:';
          return false;
        }
      case SwitchType.string:
        sw.postStrings.add(s.substring(pos));
        return true;
      case SwitchType.simple:
        break;
    }

    if (pos != s.length) {
      errorMessage = 'Too long switch:';
      return false;
    }
    return true;
  }

  /// CParser::ParseStrings
  bool parseStrings(List<SwitchForm> switchForms, List<String> commandStrings) {
    stopSwitchIndex = -1;
    errorMessage = '';
    errorLine = '';
    nonSwitchStrings.clear();
    _switches = [for (var i = 0; i < switchForms.length; i++) SwitchResult()];

    for (final s in commandStrings) {
      if (stopSwitchIndex < 0) {
        if (s == _kStopSwitchParsing) {
          stopSwitchIndex = nonSwitchStrings.length;
          continue;
        }
        if (s.isNotEmpty && _isItSwitchChar(s.codeUnitAt(0))) {
          if (_parseString(s, switchForms)) continue;
          errorLine = s;
          return false;
        }
      }
      nonSwitchStrings.add(s);
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// ListFileUtils.cpp

/// Code pages accepted by -scs (Z7_WIN_CP_UTF16, Z7_WIN_CP_UTF16BE, CP_UTF8,
/// CP_ACP, CP_OEMCP).
abstract final class CodePage {
  static const acp = 0;
  static const oemcp = 1;
  static const utf16 = 1200;
  static const utf16be = 1201;
  static const utf8 = 65001;
}

// AddName
void _addName(List<String> strings, String s) {
  s = _trimSpaces(s);
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    s = s.substring(1, s.length - 1);
  }
  if (s.isNotEmpty) strings.add(s);
}

/// Result of [readNamesFromListFile2]: the names, or an error. [lastError]
/// is the errno of a file error (0 when the content is bad).
class ListFileResult {
  final List<String>? names;
  final int lastError;
  final String? osMessage;
  const ListFileResult(this.names, this.lastError, [this.osMessage]);
}

// String.trim of the C++ code (UString::Trim) removes ' ', '\n' and '\t'.
String _trimSpaces(String s) {
  var a = 0, b = s.length;
  bool ws(int c) => c == 0x20 || c == 0x0A || c == 0x09;
  while (a < b && ws(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && ws(s.codeUnitAt(b - 1))) {
    b--;
  }
  return s.substring(a, b);
}

/// ReadNamesFromListFile2.
ListFileResult readNamesFromListFile2(String fileName, int codePage) {
  Uint8List data;
  try {
    data = File(fileName).readAsBytesSync();
  } on FileSystemException catch (e) {
    final code = e.osError?.errorCode ?? 2;
    return ListFileResult(null, code == 0 ? 2 : code, e.osError?.message);
  }
  if (data.length >= (1 << 31) - 32) return const ListFileResult(null, 0);
  String u;
  if (codePage == CodePage.utf16 || codePage == CodePage.utf16be) {
    if ((data.length & 1) != 0) return const ListFileResult(null, 0);
    final sb = StringBuffer();
    for (var i = 0; i < data.length; i += 2) {
      final c = codePage == CodePage.utf16
          ? data[i] | (data[i + 1] << 8)
          : (data[i] << 8) | data[i + 1];
      if (c == 0) return const ListFileResult(null, 0);
      sb.writeCharCode(c);
    }
    u = sb.toString();
  } else {
    // s.ReleaseBuf_CalcLen: a 0 byte ends the string, which is an error
    if (data.contains(0)) return const ListFileResult(null, 0);
    if (codePage == CodePage.utf8) {
      try {
        u = const Utf8Decoder(allowMalformed: false).convert(data);
      } on FormatException {
        return const ListFileResult(null, 0);
      }
    } else if (kIsWin) {
      u = codePageEncoding(codePage).decode(data);
    } else {
      u = latin1.decode(data);
    }
  }

  const kGoodBOM = 0xFEFF;
  final strings = <String>[];
  var i = 0;
  while (i < u.length && u.codeUnitAt(i) == kGoodBOM) {
    i++;
  }
  final s = StringBuffer();
  for (; i < u.length; i++) {
    final c = u.codeUnitAt(i);
    if (c == 0x0A || c == 0x0D) {
      _addName(strings, s.toString());
      s.clear();
    } else {
      s.writeCharCode(c);
    }
  }
  _addName(strings, s.toString());
  return ListFileResult(strings, 0);
}
