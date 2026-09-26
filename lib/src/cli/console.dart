// Console helpers of the SDK's console program: Console/PercentPrinter.cpp
// (the progress line), Console/UserInputUtils.cpp (the overwrite question
// and the password prompt), Console/ConsoleClose.cpp (break signal) and
// Console/OpenCallbackConsole.cpp.

import 'common.dart';
import 'open_archive.dart';
import 'std_stream.dart';

/// NConsoleClose: the break counter. A synchronous Dart program can not
/// receive SIGINT while it works, so this stays 0 and Ctrl+C ends the
/// process with the default action of the signal.
int gBreakCounter = 0;

// TestBreakSignal
bool testBreakSignal() => gBreakCounter != 0;

/// CheckBreak2: throws E_ABORT when a break was signaled.
void checkBreak2() {
  if (testBreakSignal()) throw const SystemException(HRes.eAbort);
}

final Stopwatch _tickClock = Stopwatch()..start();

// GetTickCount
int getTickCount() => _tickClock.elapsedMilliseconds & 0xFFFFFFFF;

const int _kPercentsSize = 4;

/// CPercentPrinterState.
class PercentPrinterState {
  int completed = 0;
  int total = -1;
  int files = 0;
  String command = '';
  String fileName = '';

  // ClearCurState
  void clearCurState() {
    completed = 0;
    total = -1;
    files = 0;
    command = '';
    fileName = '';
  }

  void _copyFrom(PercentPrinterState s) {
    completed = s.completed;
    total = s.total;
    files = s.files;
    command = s.command;
    fileName = s.fileName;
  }
}

/// CPercentPrinter.
class PercentPrinter extends PercentPrinterState {
  StdOutStream? so;
  bool disablePrint = false;
  bool needFlush = true;
  int maxLen = 80 - 1;

  final int _tickStep;
  int _prevTick = 0;
  String _printedString = '';
  final PercentPrinterState _printedState = PercentPrinterState();
  String _printedPercents = '';

  PercentPrinter([this._tickStep = 200]);

  // ClosePrint
  void closePrint(bool needFlush) {
    final num = _printedString.length;
    if (num != 0) {
      so!.write('\b' * num + ' ' * num + '\b' * num);
    }
    if (needFlush) so?.flush();
    _printedString = '';
  }

  // GetPercents
  String _getPercents() {
    var c = '%';
    var val = 0;
    if (total == -1 || (total == 0 && completed != 0)) {
      val = completed >> 20;
      c = 'M';
    } else if (total != 0) {
      val = completed * 100 ~/ total;
    }
    final s = '$val$c';
    return s.padLeft(_kPercentsSize);
  }

  // Print
  void print() {
    if (disablePrint) return;
    final so = this.so;
    if (so == null) return;
    var tick = 0;
    if (_tickStep != 0) tick = getTickCount();

    var onlyPercentsChanged = false;
    if (_printedString.isNotEmpty) {
      if (_tickStep != 0 && ((tick - _prevTick) & 0xFFFFFFFF) < _tickStep) {
        return;
      }
      if (_printedState.command == command &&
          _printedState.fileName == fileName &&
          _printedState.files == files) {
        if (_printedState.total == total &&
            _printedState.completed == completed) {
          return;
        }
        onlyPercentsChanged = true;
      }
    }

    var s = _getPercents();
    if (onlyPercentsChanged && s == _printedPercents) return;
    _printedPercents = s;

    if (files != 0) s += ' $files';
    if (command.isNotEmpty) s += ' $command';

    if (fileName.isNotEmpty && s.length < maxLen) {
      s += ' ';
      var temp = so.normalizeStringPath(fileName);
      if (s.length + temp.length > maxLen) {
        var len = fileName.length;
        while (len != 0) {
          var delta = len ~/ 8;
          if (delta == 0) delta = 1;
          len -= delta;
          final keep = len ~/ 2;
          final tail = fileName.length - (len - keep);
          temp = so.normalizeStringPath(
              '${fileName.substring(0, keep)} . ${fileName.substring(tail)}');
          if (s.length + temp.length <= maxLen) break;
        }
        if (len == 0) temp = '';
      }
      s += temp;
    }

    if (_printedString != s) {
      closePrint(false);
      so.write(s);
      if (needFlush) so.flush();
      _printedString = s;
    }
    _printedState._copyFrom(this);
    if (_tickStep != 0) _prevTick = tick;
  }
}

// ---------------------------------------------------------------------------
// UserInputUtils.cpp

/// NUserAnswerMode.
enum UserAnswerMode { yes, no, yesAll, noAll, autoRenameAll, quit, eof, error }

/// ScanUserYesNoAllQuit.
UserAnswerMode scanUserYesNoAllQuit(StdOutStream? outStream, StdInStream sin) {
  outStream?.write('? ');
  for (;;) {
    if (outStream != null) {
      outStream.write(
          '(Y)es / (N)o / (A)lways / (S)kip all / A(u)to rename all / (Q)uit? ');
      outStream.flush();
    }
    final a = sin.scanAStringUntilNewLine();
    if (a == null) return UserAnswerMode.error;
    if (sin.error) return UserAnswerMode.error;
    final scanned = String.fromCharCodes(a).trim();
    if (scanned.isEmpty && sin.eof) return UserAnswerMode.eof;
    if (scanned.length == 1) {
      switch (scanned.toLowerCase()) {
        case 'y':
          return UserAnswerMode.yes;
        case 'n':
          return UserAnswerMode.no;
        case 'a':
          return UserAnswerMode.yesAll;
        case 's':
          return UserAnswerMode.noAll;
        case 'u':
          return UserAnswerMode.autoRenameAll;
        case 'q':
          return UserAnswerMode.quit;
      }
    }
  }
}

/// Echo control of the terminal (stdin.echoMode), set by the program.
bool Function(bool echo)? gSetEcho;

// GetPassword: (ok, password)
(bool, String) _getPassword(StdOutStream? outStream, StdInStream sin) {
  // the SDK disables echo on Windows only; the port does it where the
  // terminal allows it and then prints the Windows text
  final echoOff = gSetEcho?.call(false) ?? false;
  if (outStream != null) {
    outStream.write(echoOff
        ? '\nEnter password (will not be echoed):'
        : '\nEnter password:');
    outStream.flush();
  }
  final r = sin.scanUStringUntilNewLine();
  if (echoOff) gSetEcho?.call(true);
  if (outStream != null) {
    outStream.endl();
    outStream.flush();
  }
  return r;
}

/// GetPassword_HRESULT: throws [SystemException] for errors.
String getPasswordHResult(StdOutStream? outStream, StdInStream sin) {
  final (ok, psw) = _getPassword(outStream, sin);
  if (!ok) throw const SystemException(HRes.eInvalidArg);
  if (sin.error) throw const SystemException(HRes.eFail);
  if (sin.eof && psw.isEmpty) throw const SystemException(HRes.eAbort);
  return psw;
}

// ---------------------------------------------------------------------------
// OpenCallbackConsole.cpp

/// COpenCallbackConsole.
class OpenCallbackConsole extends OpenCallbackUI {
  final PercentPrinter percent = PercentPrinter();
  StdOutStream? so;
  StdOutStream? se;
  late StdInStream stdIn;
  int _totalBytes = 0;
  bool _totalFilesDefined = false;
  bool multiArcMode = false;

  bool passwordIsDefined = false;
  String password = '';

  bool needPercents() => percent.so != null && !percent.disablePrint;

  void closePercents() {
    if (needPercents()) percent.closePrint(true);
  }

  // Init
  void init(StdOutStream? outStream, StdOutStream? errorStream,
      StdOutStream? percentStream, bool disablePercents, StdInStream sin) {
    so = outStream;
    se = errorStream;
    percent.so = percentStream;
    percent.disablePrint = disablePercents;
    stdIn = sin;
  }

  @override
  void openCheckBreak() => checkBreak2();

  @override
  void openSetTotal(int? files, int? bytes) {
    if (!multiArcMode && needPercents()) {
      if (files != null) {
        _totalFilesDefined = true;
        percent.total = files;
      } else {
        _totalFilesDefined = false;
      }
      if (bytes != null) {
        _totalBytes = bytes;
        if (files == null) percent.total = bytes;
      } else {
        if (files == null) percent.total = _totalBytes;
      }
    }
    checkBreak2();
  }

  @override
  void openSetCompleted(int? files, int? bytes) {
    if (!multiArcMode && needPercents()) {
      if (files != null) {
        percent.files = files;
        if (_totalFilesDefined) percent.completed = files;
      }
      if (bytes != null) {
        if (!_totalFilesDefined) percent.completed = bytes;
      }
      percent.print();
    }
    checkBreak2();
  }

  @override
  void openFinished() => closePercents();

  @override
  String openCryptoGetTextPassword() {
    checkBreak2();
    if (!passwordIsDefined) {
      closePercents();
      password = getPasswordHResult(so, stdIn);
      passwordIsDefined = true;
    }
    return password;
  }
}
