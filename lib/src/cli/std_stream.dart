// Console streams: Common/StdOutStream.cpp (CStdOutStream with the path and
// terminal character normalization) and Common/StdInStream.cpp
// (CStdInStream::ScanAStringUntilNewLine), over the byte sinks of [CliIo].

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../io/streams.dart';
import 'common.dart';

/// The process streams the console program uses. The real program uses the
/// file descriptors 0, 1 and 2 synchronously; tests pass memory sinks.
class CliIo {
  /// Writes raw bytes to standard output.
  final void Function(Uint8List bytes) writeOut;

  /// Writes raw bytes to standard error.
  final void Function(Uint8List bytes) writeErr;

  /// Standard input as a byte stream (-si data, prompts). null: empty.
  final InStream? stdinStream;

  final bool stdinIsTerminal;
  final bool stdoutIsTerminal;
  final bool stderrIsTerminal;

  /// Terminal width for the percent line.
  final int consoleWidth;

  /// Turns terminal echo of standard input on or off; returns false when
  /// that is not possible.
  final bool Function(bool echo)? setEcho;

  /// Flushes the standard output sink.
  final void Function()? flushOut;

  /// The current working directory used to resolve relative paths.
  final String? workingDirectory;

  /// fstat(0): the file information of the standard input, or null.
  final FileStat? Function()? statStdin;

  const CliIo({
    required this.writeOut,
    required this.writeErr,
    this.stdinStream,
    this.stdinIsTerminal = false,
    this.stdoutIsTerminal = false,
    this.stderrIsTerminal = false,
    this.consoleWidth = 80,
    this.setEcho,
    this.flushOut,
    this.workingDirectory,
    this.statStdin,
  });
}

// IsDangerousTerminalChar
bool _isDangerousTerminalChar(int c) {
  if (c < 0x20) return true;
  if (c < 0x7F) return false;
  if (c < 0x9F + 1) return true;
  if (c < 0x202A) return false;
  if (c < 0x202E + 1) return true;
  if (c < 0x2066) return false;
  if (c < 0x2069 + 1) return true;
  return false;
}

/// CStdOutStream.
class StdOutStream {
  final void Function(Uint8List bytes) _write;
  final void Function()? _flushSink;

  /// Buffered like the C stdio stream: stdout is fully buffered (line
  /// buffered on a terminal), stderr is unbuffered.
  final bool buffered;
  final BytesBuilder _buf = BytesBuilder(copy: false);

  bool isTerminalMode = false;
  final BoolPair2 listPathSeparatorSlash = BoolPair2(true);
  int codePage = -1;

  StdOutStream(this._write, {this.buffered = true, void Function()? flush})
      : _flushSink = flush;

  void _emit(Uint8List b) {
    if (!buffered) {
      _write(b);
      return;
    }
    _buf.add(b);
    if (_buf.length >= (1 << 16)) _drain();
  }

  void _drain() {
    if (_buf.isEmpty) return;
    _write(_buf.takeBytes());
  }

  /// operator<< (const char *) and PrintUString: the text in UTF-8
  /// (CP_UTF8 on POSIX).
  StdOutStream operator <<(Object? s) {
    write(s);
    return this;
  }

  void write(Object? s) {
    final str = '$s';
    if (str.isEmpty) return;
    _emit(Uint8List.fromList(utf8.encode(str)));
    if (isTerminalMode && buffered && str.contains('\n')) flush();
  }

  /// operator<<(char) with a raw byte.
  void writeBytes(Uint8List b) => _emit(b);

  /// endl
  void endl() => write('\n');

  /// Flush
  void flush() {
    _drain();
    _flushSink?.call();
  }

  // Normalize_UString
  String normalizeString(String s) {
    final r = StringBuffer();
    for (final c in s.runes) {
      if (isTerminalMode) {
        r.writeCharCode(_isDangerousTerminalChar(c) ? 0x5F : c);
      } else {
        r.writeCharCode(c == 0x0A ? 0x5F : c);
      }
    }
    return r.toString();
  }

  // Normalize_UString_Path
  String normalizeStringPath(String s) {
    if (listPathSeparatorSlash.def && !listPathSeparatorSlash.val) {
      s = s.replaceAll('/', '\\');
    }
    return normalizeString(s);
  }

  // NormalizePrint_UString_Path
  void normalizePrintPath(String s) => write(normalizeStringPath(s));

  // NormalizePrint_UString
  void normalizePrint(String s) => write(normalizeString(s));
}

/// CStdInStream over the byte stream of [CliIo].
class StdInStream {
  final InStream? _s;
  final Uint8List _buf = Uint8List(1 << 12);
  int _pos = 0;
  int _len = 0;
  bool _eof = false;
  bool _error = false;
  int codePage = -1;

  StdInStream(this._s);

  bool get eof => _eof;
  bool get error => _error;

  /// The underlying stream for -si data: the bytes not yet consumed by
  /// line reads come first.
  InStream get dataStream => _StdInData(this);

  // GetChar: -1 at the end.
  int getChar() {
    if (_pos < _len) return _buf[_pos++];
    if (_eof || _s == null) {
      _eof = true;
      return -1;
    }
    try {
      _len = _s.read(_buf, 0, _buf.length);
    } on Object {
      _error = true;
      _len = 0;
    }
    _pos = 0;
    if (_len == 0) {
      _eof = true;
      return -1;
    }
    return _buf[_pos++];
  }

  /// ScanAStringUntilNewLine: returns null for a 0 byte (error).
  List<int>? scanAStringUntilNewLine() {
    final s = <int>[];
    for (;;) {
      final c = getChar();
      if (c < 0) return s;
      if (c == 0) return null;
      if (c == 0x0A) return s;
      s.add(c);
    }
  }

  /// ScanUStringUntilNewLine: (ok, text).
  (bool, String) scanUStringUntilNewLine() {
    final a = scanAStringUntilNewLine();
    final bytes = a ?? const <int>[];
    return (a != null, utf8.decode(bytes, allowMalformed: true));
  }
}

class _StdInData implements InStream {
  final StdInStream _in;
  _StdInData(this._in);
  @override
  int read(Uint8List buf, int off, int len) {
    if (len == 0) return 0;
    final i = _in;
    if (i._pos < i._len) {
      var n = i._len - i._pos;
      if (n > len) n = len;
      buf.setRange(off, off + n, i._buf, i._pos);
      i._pos += n;
      return n;
    }
    if (i._eof || i._s == null) return 0;
    final n = i._s.read(buf, off, len);
    if (n == 0) i._eof = true;
    return n;
  }
}

// ---------------------------------------------------------------------------
// The real process streams.

/// Synchronous writer for a standard file descriptor. On Linux the stream
/// is reopened as /dev/stdout or /dev/stderr so writes are blocking and
/// unbuffered; elsewhere the dart:io sink is used.
class _FdSink {
  final IOSink _fallback;
  final String _devPath;
  RandomAccessFile? _raf;
  bool _tried = false;
  _FdSink(this._fallback, this._devPath);

  void add(Uint8List b) {
    if (!_tried) {
      _tried = true;
      if (Platform.isLinux || Platform.isMacOS) {
        try {
          _raf = File(_devPath).openSync(mode: FileMode.writeOnlyAppend);
        } on Object {
          _raf = null;
        }
      }
    }
    final raf = _raf;
    if (raf != null) {
      try {
        raf.writeFromSync(b);
        return;
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode ?? 0;
        if (code == 32) throw const SystemException(HRes.eAbort); // EPIPE
        rethrow;
      }
    }
    _fallback.add(b);
  }
}

/// Synchronous reader of the standard input.
class _StdinReader implements InStream {
  RandomAccessFile? _raf;
  bool _tried = false;

  @override
  int read(Uint8List buf, int off, int len) {
    if (len == 0) return 0;
    if (!_tried) {
      _tried = true;
      if (Platform.isLinux || Platform.isMacOS) {
        try {
          _raf = File('/dev/stdin').openSync();
        } on Object {
          _raf = null;
        }
      }
    }
    final raf = _raf;
    if (raf != null) return raf.readIntoSync(buf, off, off + len);
    // slow fallback
    var n = 0;
    while (n < len) {
      final c = stdin.readByteSync();
      if (c < 0) break;
      buf[off + n++] = c;
      if (c == 0x0A) break;
    }
    return n;
  }
}

/// The [CliIo] of the running process.
CliIo processCliIo() {
  final out = _FdSink(stdout, '/dev/stdout');
  final err = _FdSink(stderr, '/dev/stderr');
  var width = 80;
  bool outTerm = false, errTerm = false, inTerm = false;
  try {
    outTerm = stdout.hasTerminal;
    if (outTerm) width = stdout.terminalColumns;
  } on Object {
    width = 80;
  }
  try {
    errTerm = stderr.hasTerminal;
  } on Object {
    errTerm = false;
  }
  try {
    inTerm = stdin.hasTerminal;
  } on Object {
    inTerm = false;
  }
  return CliIo(
    writeOut: out.add,
    writeErr: err.add,
    stdinStream: _StdinReader(),
    stdinIsTerminal: inTerm,
    stdoutIsTerminal: outTerm,
    stderrIsTerminal: errTerm,
    consoleWidth: width,
    statStdin: () {
      try {
        return FileStat.statSync('/dev/stdin');
      } on Object {
        return null;
      }
    },
    setEcho: (echo) {
      try {
        if (!stdin.hasTerminal) return false;
        stdin.echoMode = echo;
        return true;
      } on Object {
        return false;
      }
    },
  );
}
