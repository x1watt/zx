// Console output of the "h" command and of the -scrc hash summary:
// Console/HashCon.cpp of the LZMA SDK (CHashCallbackConsole, PrintHashStat).

import 'common.dart';
import 'console.dart';
import 'enum_dir_items.dart';
import 'extract_callback_console.dart' show printDirItemsStat;
import 'hash_calc.dart';
import 'std_stream.dart';
import 'update_callback_console.dart';
import 'platform.dart';

const String _kEmptyFileAlias = '[Content]';
const int _kSizeFieldLen = 13;
const int _kNameFieldLen = 12;
const int _kHashColumnWidthMin = 4 * 2;

// GetColumnWidth
int _getColumnWidth(int digestSize) {
  final width = digestSize * 2;
  return width < _kHashColumnWidthMin ? _kHashColumnWidthMin : width;
}

/// CHashCallbackConsole.
class HashCallbackConsole extends CallbackConsoleBase implements HashCallbackUI {
  String _fileName = '';
  final StringBuffer _s = StringBuffer();
  bool printNameInPercents = true;
  bool printHeaders = false;
  String printFields = '';

  void init(StdOutStream? outStream, StdOutStream? errorStream,
      StdOutStream? percentStream, bool disablePercents) =>
      initBase(outStream, errorStream, percentStream, disablePercents);

  // AddSpace
  void _addSpace() {
    if (_s.isNotEmpty) _s.write(' ');
  }

  // AddSpacesBeforeName
  void _addSpacesBeforeName() {
    if (_s.isNotEmpty) _s.write('  ');
  }

  @override
  void startScanning() {
    if (printHeaders) so?.write('Scanning\n');
    if (needPercents()) {
      percent.clearCurState();
      percent.command = 'Scan';
    }
    checkBreak2();
  }

  @override
  void scanProgress(DirItemsStat st, String path, bool isDir) {
    if (needPercents()) {
      percent.files = st.numDirs + st.numFiles + st.numAltStreams;
      percent.completed = st.getTotalBytes();
      var p = path;
      if (isDir) p = normalizeDirPathPrefix(p);
      percent.fileName = p;
      percent.print();
    }
    checkBreak2();
  }

  @override
  void scanError(String path, int systemError) =>
      scanErrorBase(path, systemError);

  @override
  void finishScanning(DirItemsStat st) {
    if (needPercents()) {
      percent.closePrint(true);
      percent.clearCurState();
    }
    if (printHeaders && so != null) {
      _s.write(printDirItemsStat(st));
      so!.write('$_s\n\n');
    }
    checkBreak2();
  }

  @override
  void setNumFiles(int numFiles) => checkBreak2();

  @override
  void setTotal(int size) {
    if (needPercents()) {
      percent.total = size;
      percent.print();
    }
    checkBreak2();
  }

  @override
  void setCompleted(int completeValue) {
    if (needPercents()) {
      percent.completed = completeValue;
      percent.print();
    }
    checkBreak2();
  }

  // GetFields
  String _getFields() {
    final s = printFields.isEmpty ? 'hsn' : printFields;
    return s.toLowerCase();
  }

  // PrintSeparatorLine
  void _printSeparatorLine(List<HasherState> hashers) {
    _s.clear();
    final fields = _getFields();
    for (var pos = 0; pos < fields.length; pos++) {
      final c = fields[pos];
      if (c == 'h') {
        for (final h in hashers) {
          _addSpace();
          _s.write('-' * _getColumnWidth(h.digestSize));
        }
      } else if (c == 's') {
        _addSpace();
        _s.write('-' * _kSizeFieldLen);
      } else if (c == 'n') {
        _addSpacesBeforeName();
        _s.write('-' * _kNameFieldLen);
      }
    }
    so!.write('$_s\n');
  }

  @override
  void beforeFirstFile(HashBundle hb) {
    if (printHeaders && so != null) {
      _s.clear();
      closePercentsForSo();
      final fields = _getFields();
      for (var pos = 0; pos < fields.length; pos++) {
        final c = fields[pos];
        if (c == 'h') {
          for (final h in hb.hashers) {
            _addSpace();
            _s.write(h.name);
            final n = _getColumnWidth(h.digestSize) - h.name.length;
            if (n > 0) _s.write(' ' * n);
          }
        } else if (c == 's') {
          _addSpace();
          const s2 = 'Size';
          _s.write(' ' * (_kSizeFieldLen - s2.length));
          _s.write(s2);
        } else if (c == 'n') {
          _addSpacesBeforeName();
          _s.write('Name');
        }
      }
      so!.write('$_s\n');
      _printSeparatorLine(hb.hashers);
    }
    checkBreak2();
  }

  @override
  void openFileError(String path, int systemError) =>
      openFileErrorBase(path, systemError);

  @override
  void getStream(String name, bool isDir) {
    _fileName = name;
    if (isDir && _fileName.isNotEmpty && !endsWithPathSepar(_fileName)) {
      _fileName += kDirSep;
    }
    if (needPercents()) {
      if (printNameInPercents) percent.fileName = name;
      percent.print();
    }
    checkBreak2();
  }

  // PrintResultLine
  void _printResultLine(int fileSize, List<HasherState> hashers,
      int digestIndex, bool showHash, String path) {
    closePercentsForSo();
    _s.clear();
    final fields = _getFields();
    for (var pos = 0; pos < fields.length; pos++) {
      final c = fields[pos];
      if (c == 'h') {
        for (final h in hashers) {
          _addSpace();
          var s = showHash ? h.writeToString(digestIndex) : '';
          final n = _getColumnWidth(h.digestSize) - s.length;
          if (n > 0) s += ' ' * n;
          _s.write(s);
        }
      } else if (c == 's') {
        _addSpace();
        var p = ' ' * _kSizeFieldLen;
        if (showHash) {
          p = u64ToString(fileSize);
          final numSpaces = _kSizeFieldLen - p.length;
          if (numSpaces > 0) p = ' ' * numSpaces + p;
        }
        _s.write(p);
      } else if (c == 'n') {
        _addSpacesBeforeName();
        _s.write(path);
      }
    }
    so!.write(_s.toString());
  }

  @override
  void setOperationResult(int fileSize, HashBundle hb, bool showHash) {
    final so = this.so;
    if (so != null) {
      String s;
      if (_fileName.isEmpty) {
        s = _kEmptyFileAlias;
      } else {
        s = so.normalizeStringPath(_fileName);
      }
      _printResultLine(fileSize, hb.hashers, kHashCalcIndexCurrent, showHash, s);
      so.endl();
    }
    if (needPercents()) {
      percent.files++;
      percent.print();
    }
    checkBreak2();
  }

  // PrintProperty
  void _printProperty(String name, int value) =>
      so!.write('$name: ${u64ToString(value)}\n');

  @override
  void afterLastFile(HashBundle hb) {
    closePercents2();
    if (printHeaders && so != null) {
      _printSeparatorLine(hb.hashers);
      _printResultLine(
          hb.filesSize, hb.hashers, kHashCalcIndexDataSum, true, '');
      so!.write('\n\n');
      if (hb.numFiles != 1 || hb.numDirs != 0) {
        if (hb.numDirs != 0) _printProperty('Folders', hb.numDirs);
        _printProperty('Files', hb.numFiles);
      }
      _printProperty('Size', hb.filesSize);
      if (hb.numAltStreams != 0) {
        _printProperty('Alternate streams', hb.numAltStreams);
        _printProperty('Alternate streams size', hb.altStreamsSize);
      }
      so!.endl();
      printHashStat(so!, hb);
    }
  }
}

const List<String> _kDigestTitles = [
  ' : ',
  ' for data:              ',
  ' for data and names:    ',
  ' for streams and names: ',
];

// PrintSum
void _printSum(StdOutStream so, HasherState h, int digestIndex) {
  so.write(h.name);
  final n = 6 - h.name.length;
  if (n > 0) so.write(' ' * n);
  so.write(_kDigestTitles[digestIndex]);
  so.write('${h.writeToString(digestIndex)}\n');
}

/// PrintHashStat.
void printHashStat(StdOutStream so, HashBundle hb) {
  for (final h in hb.hashers) {
    _printSum(so, h, kHashCalcIndexDataSum);
    if (hb.numFiles != 1 || hb.numDirs != 0) {
      _printSum(so, h, kHashCalcIndexNamesSum);
    }
    if (hb.numAltStreams != 0) {
      _printSum(so, h, kHashCalcIndexStreamsSum);
    }
    so.endl();
  }
}
