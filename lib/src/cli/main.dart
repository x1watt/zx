// The console program: Console/Main.cpp (Main2: the banner, the help text,
// the "i" command and the dispatch of the commands) and Console/MainAr.cpp
// (the exception handlers and exit codes) of the LZMA SDK, 7zr variant.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../codec/registry.dart';
import '../format/sevenz/method_factory.dart';
import '../io/streams.dart';
import 'archive_command_line.dart';
import 'bench.dart' show benchCon;
import 'common.dart';
import 'console.dart';
import 'enum_dir_items.dart' show enumerateDirItemsAndSort;
import 'extract.dart';
import 'extract_callback_console.dart';
import 'globals.dart';
import 'hash_calc.dart';
import 'hash_con.dart';
import 'list.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'std_stream.dart';
import 'update.dart';
import 'update_callback_console.dart';
import 'wildcard.dart';
import 'extracting_file_path.dart';
import 'prop_id_utils.dart';
import 'platform.dart';

const String _kVersion = '26.01';
const String _kZxVersion = '0.1.0';

String _cpuName() {
  final v = Platform.version;
  if (v.contains('_x64')) return 'x64';
  if (v.contains('_arm64')) return 'arm64';
  if (v.contains('_ia32')) return 'x86';
  if (v.contains('_riscv64')) return 'riscv64';
  if (v.contains('_arm')) return 'arm';
  return 'x64';
}

// The banner names this port, not 7-Zip: 7-Zip is Igor Pavlov's trademark
// and this program is not his build.
String _copyrightString() =>
    '\nzx $_kZxVersion (${_cpuName()}) : Dart port of 7-Zip $_kVersion '
    '(LZMA SDK, Igor Pavlov, public domain) : '
    'Copyright (c) 2026 Max Brito : BSD 3-clause\n';

const String _kHelpString = 'Usage: zx'
    ' <command> [<switches>...] <archive_name> [<file_names>...] [@listfile]\n'
    '\n'
    '<Commands>\n'
    '  a : Add files to archive\n'
    '  b : Benchmark\n'
    '  d : Delete files from archive\n'
    '  e : Extract files from archive (without using directory names)\n'
    '  h : Calculate hash values for files\n'
    '  i : Show information about supported formats\n'
    '  l : List contents of archive\n'
    '  rn : Rename files in archive\n'
    '  t : Test integrity of archive\n'
    '  u : Update files to archive\n'
    '  x : eXtract files with full paths\n'
    '\n'
    '<Switches>\n'
    '  -- : Stop switches and @listfile parsing\n'
    '  -ai[r[-|0]][m[-|2]][w[-]]{@listfile|!wildcard} : Include archives\n'
    '  -ax[r[-|0]][m[-|2]][w[-]]{@listfile|!wildcard} : eXclude archives\n'
    '  -ao{a|s|t|u} : set Overwrite mode\n'
    '  -an : disable archive_name field\n'
    '  -bb[0-3] : set output log level\n'
    '  -bd : disable progress indicator\n'
    '  -bs{o|e|p}{0|1|2} : set output stream for output/error/progress line\n'
    '  -bt : show execution time statistics\n'
    '  -i[r[-|0]][m[-|2]][w[-]]{@listfile|!wildcard} : Include filenames\n'
    '  -m{Parameters} : set compression Method\n'
    '    -mmt[N] : set number of CPU threads\n'
    '    -mx[N] : set compression level: -mx1 (fastest) ... -mx9 (ultra)\n'
    '  -o{Directory} : set Output directory\n'
    '  -p{Password} : set Password\n'
    '  -r[-|0] : Recurse subdirectories for name search\n'
    '  -sa{a|e|s} : set Archive name mode\n'
    '  -scc{UTF-8|WIN|DOS} : set charset for console input/output\n'
    '  -scs{UTF-8|UTF-16LE|UTF-16BE|WIN|DOS|{id}} : set charset for list files\n'
    '  -scrc[CRC32|CRC64|SHA256|*] : set hash function for x, e, h commands\n'
    '  -sdel : delete files after compression\n'
    '  -seml[.] : send archive by email\n'
    '  -sfx[{name}] : Create SFX archive\n'
    '  -si[{name}] : read data from stdin\n'
    '  -slp : set Large Pages mode\n'
    '  -slt : show technical information for l (List) command\n'
    '  -snh : store hard links as links\n'
    '  -snl : store symbolic links as links\n'
    '  -sni : store NT security information\n'
    '  -sns[-] : store NTFS alternate streams\n'
    '  -so : write data to stdout\n'
    '  -spd : disable wildcard matching for file names\n'
    '  -spe : eliminate duplication of root folder for extract command\n'
    '  -spf[2] : use fully qualified file paths\n'
    '  -ssc[-] : set sensitive case mode\n'
    '  -sse : stop archive creating, if it can\'t open some input file\n'
    '  -ssp : do not change Last Access Time of source files while archiving\n'
    '  -ssw : compress shared files\n'
    '  -stl : set archive timestamp from the most recently modified file\n'
    '  -stm{HexMask} : set CPU thread affinity mask (hexadecimal number)\n'
    '  -stx{Type} : exclude archive type\n'
    '  -t{Type} : Set type of archive\n'
    '  -u[-][p#][q#][r#][x#][y#][z#][!newArchiveName] : Update options\n'
    '  -v{Size}[b|k|m|g] : Create volumes\n'
    '  -w[{path}] : assign Work directory. Empty path means a temporary directory\n'
    '  -x[r[-|0]][m[-|2]][w[-]]{@listfile|!wildcard} : eXclude filenames\n'
    '  -y : assume Yes on all queries\n';

const String _kEverythingIsOk = 'Everything is Ok';
const String _kUserErrorMessage = 'Incorrect command line';
const String _kUnsupportedArcTypeMessage = 'Unsupported archive type';

// GetLocale after MY_SetLocale
String _getLocale() {
  final env = Platform.environment;
  for (final k in ['LC_ALL', 'LC_CTYPE', 'LANG']) {
    final v = env[k];
    if (v != null && v.isNotEmpty) {
      if (v == 'C' || v == 'POSIX') return 'C.UTF-8';
      return v;
    }
  }
  return 'C.UTF-8';
}

// Get_File_OPEN_MAX after the RLIMIT_NOFILE increase of Main2
int _openMax() {
  try {
    for (final line in File('/proc/self/limits').readAsLinesSync()) {
      if (line.startsWith('Max open files')) {
        final parts = line.substring(14).trim().split(RegExp(r'\s+'));
        final soft = int.tryParse(parts[0]) ?? 1024;
        final hard = parts[1] == 'unlimited' ? 1 << 30 : int.tryParse(parts[1]);
        var v = soft;
        const newVal = 1 << 12;
        if (hard != null && newVal > soft && soft < hard) {
          v = newVal > hard ? hard : newVal;
        }
        return v;
      }
    }
  } on Object {
    // not Linux
  }
  if (kIsMac) {
    // no /proc on macOS: the soft and hard RLIMIT_NOFILE of this process
    // are the ones a child shell inherits
    try {
      final r = Process.runSync('/bin/sh', ['-c', 'ulimit -n; ulimit -Hn']);
      final lines = (r.stdout as String).trim().split(RegExp(r'\s+'));
      final soft = int.tryParse(lines[0]) ?? 256;
      final hard = lines.length > 1
          ? (lines[1] == 'unlimited' ? 1 << 30 : int.tryParse(lines[1]))
          : null;
      const newVal = 1 << 12;
      if (hard != null && newVal > soft && soft < hard) {
        return newVal > hard ? hard : newVal;
      }
      return soft;
    } on Object {
      return 1024;
    }
  }
  return 1024;
}

// ShowProgInfo
void _showProgInfo(StdOutStream so) {
  final sb = StringBuffer(' 64-bit');
  final locale = _getLocale();
  sb.write(' locale=$locale');
  if (!locale.toUpperCase().contains('UTF-8') &&
      !locale.toUpperCase().contains('UTF8')) {
    sb.write(' UTF8=-');
  }
  sb.write(' Threads:${Platform.numberOfProcessors}');
  sb.write(' OPEN_MAX:${_openMax()}');
  if (!Directory('/tmp').existsSync()) sb.write(' temp_path:./');
  so.write('$sb\n');
}

// ShowCopyrightAndHelp (ShowProgInfo is empty on Windows)
void _showCopyrightAndHelp(StdOutStream? so, bool needHelp) {
  if (so == null) return;
  so.write(_copyrightString());
  if (!kIsWin) _showProgInfo(so);
  so.endl();
  if (needHelp) so.write(_kHelpString);
}

// PrintWarningsPaths
void _printWarningsPaths(ErrorPathCodes pc, StdOutStream so) {
  for (var i = 0; i < pc.paths.length; i++) {
    so.normalizePrintPath(pc.paths[i]);
    so.write(' : ${myFormatMessage(pc.codes[i])}\n');
  }
  so.write('----------------\n');
}

// WarningsCheck
int _warningsCheck(int result, CallbackConsoleBase callback,
    UpdateErrorInfo errorInfo, StdOutStream? so, StdOutStream? se,
    bool showHeaders) {
  var exitCode = ExitCode.success;
  if (callback.scanErrors.paths.isNotEmpty) {
    if (se != null) {
      se.write('\nScan WARNINGS for files and folders:\n\n');
      _printWarningsPaths(callback.scanErrors, se);
      se.write('Scan WARNINGS: ${callback.scanErrors.paths.length}\n');
    }
    exitCode = ExitCode.warning;
  }
  if (result != HRes.sOk || errorInfo.thereIsError()) {
    if (se != null) {
      final message = StringBuffer();
      if (errorInfo.message.isNotEmpty) message.write('${errorInfo.message}\n');
      for (final f in errorInfo.fileNames) {
        message.write('$f\n');
      }
      if (errorInfo.systemError != 0) {
        message.write('${myFormatMessage(errorInfo.systemError)}\n');
      }
      if (message.isNotEmpty) se.write('\nError:\n$message');
    }
    return ExitCode.fatalError;
  }
  final numErrors = callback.failedFiles.paths.length;
  if (numErrors == 0) {
    if (showHeaders) {
      if (callback.scanErrors.paths.isEmpty) {
        if (so != null) {
          se?.flush();
          so.write('$_kEverythingIsOk\n');
        }
      }
    }
  } else {
    if (se != null) {
      se.write('\nWARNINGS for files:\n\n');
      _printWarningsPaths(callback.failedFiles, se);
      se.write('WARNING: Cannot open $numErrors file');
      if (numErrors > 1) se.write('s');
      se.endl();
    }
    exitCode = ExitCode.warning;
  }
  return exitCode;
}

// PrintNum
String _printNum(int val, int numDigits, [String c = ' ']) =>
    '$val'.padLeft(numDigits, c);

// PrintTime (POSIX)
void _printTime(String s, int val, int totalUs, int kFreq) {
  final so = gStdStream!;
  so.write('\n$s Time =');
  int sec, ms;
  if (kFreq == 0) {
    sec = val ~/ 1000000;
    ms = val % 1000000 ~/ 1000;
  } else {
    sec = val ~/ kFreq;
    ms = (val - sec * kFreq) * 1000 ~/ kFreq;
  }
  so.write(_printNum(sec, 6));
  so.write('.');
  so.write(_printNum(ms, 3, '0'));
  if (totalUs == 0) return;
  var percent = 0;
  if (kFreq == 0) {
    percent = val * 100 ~/ totalUs;
  } else {
    percent = val * 1000000 ~/ kFreq * 100 ~/ totalUs;
  }
  so.write(' =');
  so.write(_printNum(percent, 5));
  so.write('%');
}

// PrintTime (_WIN32): FILETIME ticks.
void _printTimeWin(String s, int val, int total) {
  final so = gStdStream!;
  so.write('\n$s Time =');
  const kFreq = 10000000;
  final sec = val ~/ kFreq;
  so.write(_printNum(sec, 6));
  so.write('.');
  final ms = (val - sec * kFreq) ~/ (kFreq ~/ 1000);
  so.write(_printNum(ms, 3, '0'));
  while (val > (1 << 56)) {
    val >>= 1;
    total >>= 1;
  }
  var percent = 0;
  if (total != 0) percent = val * 100 ~/ total;
  so.write(' =');
  so.write(_printNum(percent, 5));
  so.write('%');
}

// PrintStat (_WIN32): GetProcessTimes and GetProcessMemoryInfo can not be
// called from dart:io, so the kernel, user and process times and the
// virtual memory are left out; the global time and the peak working set
// (ProcessInfo.maxRss) are printed in the layout of the SDK.
void _printStatWin(int startTimeUs) {
  final totalTime = (DateTime.now().microsecondsSinceEpoch - startTimeUs) * 10;
  _printTimeWin('Global ', totalTime, totalTime);
  try {
    final peak = ProcessInfo.maxRss;
    final so = gStdStream!;
    so.write('    Physical Memory =');
    so.write(_printNum((peak + (1 << 20) - 1) >> 20, 7));
    so.write(' MB');
  } on Object {
    // memDefined = false
  }
  gStdStream!.endl();
}

// PrintStat: times(): user and kernel times of the process from /proc
void _printStat(int startTimeUs) {
  if (kIsWin) {
    _printStatWin(startTimeUs);
    return;
  }
  final totalTime = DateTime.now().microsecondsSinceEpoch - startTimeUs;
  var utime = 0, stime = 0;
  const kFreq = 100; // sysconf(_SC_CLK_TCK) on Linux
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    utime = int.parse(rest[11]);
    stime = int.parse(rest[12]);
  } on Object {
    // not Linux
  }
  _printTime('Kernel ', stime, totalTime, kFreq);
  _printTime('User   ', utime, totalTime, kFreq);
  _printTime('Process', utime + stime, totalTime, kFreq);
  _printTime('Global ', totalTime, totalTime, 0);
  gStdStream!.endl();
}

// PrintHexId
String _printHexId(int id) => hexUpper(id).padLeft(8);

void _printInfo(Codecs codecs) {
  final so = gStdStream ?? gStdOut;
  so.write('\nFormats:\n');
  const kArcFlags = 'KSNFMGOPBELHXCc+a+m+r+';
  for (final arc in codecs.formats) {
    final sb = StringBuffer('   ');
    sb.write(arc.updateEnabled ? 'C' : ' ');
    for (var b = 0; b < kArcFlags.length; b++) {
      sb.write((arc.flags & (1 << b)) != 0 ? kArcFlags[b] : '.');
    }
    sb.write(' ');
    sb.write(' ');
    sb.write(arc.name.padRight(8));
    sb.write(' ');
    final s = StringBuffer();
    for (var t = 0; t < arc.exts.length; t++) {
      if (t != 0) s.write(' ');
      final ext = arc.exts[t];
      s.write(ext.ext);
      if (ext.addExt.isNotEmpty) s.write(' (${ext.addExt})');
    }
    sb.write(s.toString().padRight(13));
    sb.write(' ');
    if (arc.signatureOffset != 0) sb.write('offset=${arc.signatureOffset} ');
    for (var si = 0; si < arc.signatures.length; si++) {
      if (si != 0) sb.write('  ||  ');
      final sig = arc.signatures[si];
      for (var j = 0; j < sig.length; j++) {
        if (j != 0) sb.write(' ');
        final b = sig[j];
        if (b > 0x20 && b < 0x80) {
          sb.writeCharCode(b);
        } else {
          sb.write(hexUpper(b >> 4));
          sb.write(hexUpper(b & 15));
        }
      }
    }
    so.write('$sb\n');
  }
  so.write('\nCodecs:\n');
  for (final cod in kCodecs) {
    final sb = StringBuffer('   ');
    sb.write(cod.numStreams == 1 ? ' ' : '${cod.numStreams}');
    sb.write(cod.encoder ? 'E' : ' ');
    sb.write(cod.decoder ? 'D' : ' ');
    sb.write(cod.isFilter ? 'F' : ' ');
    sb.write(' ');
    sb.write(_printHexId(cod.id));
    sb.write(' ${cod.name}');
    so.write('$sb\n');
  }
  so.write('\nHashers:\n');
  for (final (size, id, name) in kHashers) {
    so.write('   ${'$size'.padLeft(4)} ${_printHexId(id)} $name\n');
  }
}

// Main2
int _main2(List<String> commandStrings, CliIo io) {
  registerAllCodecs();
  registerSevenZipMethods();
  final startTime = DateTime.now().microsecondsSinceEpoch;

  if (commandStrings.isEmpty) {
    _showCopyrightAndHelp(gStdStream, true);
    return 0;
  }

  final options = ArcCmdLineOptions();
  final parser = ArcCmdLineParser();
  parser.parse1(commandStrings, options,
      stdinTerminal: io.stdinIsTerminal,
      stdoutTerminal: io.stdoutIsTerminal,
      stderrTerminal: io.stderrIsTerminal);

  gStdOut.isTerminalMode = options.isStdOutTerminal;
  gStdErr.isTerminalMode = options.isStdErrTerminal;

  if (options.numberForOut != kOutStreamStdout) {
    gStdStream = options.numberForOut == kOutStreamStderr ? gStdErr : null;
  }
  if (options.numberForErrors != kOutStreamStderr) {
    gErrStream = options.numberForErrors == kOutStreamStdout ? gStdOut : null;
  }
  StdOutStream? percentsStream;
  if (options.numberForPercents != kOutStreamDisabled) {
    percentsStream =
        options.numberForPercents == kOutStreamStderr ? gStdErr : gStdOut;
  }

  if (options.helpMode) {
    _showCopyrightAndHelp(gStdStream, true);
    return 0;
  }

  if (options.enableHeaders) {
    final so = gStdStream;
    if (so != null) {
      _showCopyrightAndHelp(so, false);
      if (parser.parse1Log.isNotEmpty) so.write(parser.parse1Log);
    }
  }

  parser.parse2(options);

  {
    final cp = options.consoleCodePage;
    if (cp != -1) {
      gStdOut.codePage = cp;
      gStdErr.codePage = cp;
      gStdIn.codePage = cp;
    }
  }
  gStdOut.listPathSeparatorSlash
    ..val = options.listPathSeparatorSlash.val
    ..def = options.listPathSeparatorSlash.def;
  gStdErr.listPathSeparatorSlash
    ..val = options.listPathSeparatorSlash.val
    ..def = options.listPathSeparatorSlash.def;

  var percentsNameLevel = 1;
  if (options.logLevel == 0 ||
      options.numberForPercents != options.numberForOut) {
    percentsNameLevel = 2;
  }
  final consoleWidth = io.consoleWidth;

  final codecs = Codecs.load();
  final isExtractGroupCommand = options.command.isFromExtractGroup();

  final types = parseOpenTypes(codecs, options.arcType);
  if (types == null) throw const StringException(_kUnsupportedArcTypeMessage);

  final excludedFormats = <int>[];
  for (final t in options.excludedArcTypes) {
    final tempIndices = codecs.findFormatsForArchiveType(t);
    if (tempIndices == null || tempIndices.length != 1) {
      throw const StringException(_kUnsupportedArcTypeMessage);
    }
    if (!excludedFormats.contains(tempIndices[0])) {
      excludedFormats.add(tempIndices[0]);
      excludedFormats.sort();
    }
  }

  var retCode = ExitCode.success;
  var hresultMain = HRes.sOk;

  if (options.command.commandType == CommandType.info) {
    _printInfo(codecs);
  } else if (options.command.commandType == CommandType.benchmark) {
    final so = gStdStream ?? gStdOut;
    hresultMain =
        benchCon(options.properties, options.numIterations, so);
    if (hresultMain == HRes.sFalse) {
      so.endl();
      gErrStream?.write('\nDecoding ERROR\n');
      retCode = ExitCode.fatalError;
      hresultMain = HRes.sOk;
    }
  } else if (isExtractGroupCommand ||
      options.command.commandType == CommandType.list) {
    var arcPathsSorted = <String>[];
    var arcPathsFullSorted = <String>[];

    if (options.stdInMode) {
      arcPathsSorted.add(options.arcNameForStdInMode);
      arcPathsFullSorted.add(options.arcNameForStdInMode);
    } else {
      final scan = ExtractScanConsole()
        ..init(options.enableHeaders ? gStdStream : null, gErrStream,
            percentsStream, options.disablePercents)
        ..setWindowWidth(consoleWidth);
      if (gStdStream != null && options.enableHeaders) {
        gStdStream!.write('Scanning the drive for archives:\n');
      }
      scan.startScanning();
      try {
        final (sorted, full, st) = enumerateDirItemsAndSort(
            options.arcCensor, CensorPathMode.relatPath, '', scan);
        arcPathsSorted = sorted;
        arcPathsFullSorted = full;
        scan.closeScanning();
        if (options.enableHeaders) scan.printStat(st);
      } on SystemException catch (e) {
        scan.closeScanning();
        hresultMain = e.errorCode;
      }
    }

    if (hresultMain == HRes.sOk) {
      if (isExtractGroupCommand) {
        final ecs = ExtractCallbackConsole()
          ..passwordIsDefined = options.passwordEnabled
          ..password = options.password;
        ecs.init(gStdStream, gErrStream, percentsStream,
            options.disablePercents, gStdIn);
        ecs.multiArcMode = arcPathsSorted.length > 1;
        ecs.logLevel = options.logLevel;
        ecs.percentsNameLevel = percentsNameLevel;
        if (percentsStream != null) ecs.setWindowWidth(consoleWidth);

        final eo = options.extractOptions
          ..stdInMode = options.stdInMode
          ..stdOutMode = options.stdOutMode
          ..yesToAll = options.yesToAll
          ..testMode = options.command.isTestCommand()
          ..properties = options.properties;

        final errorMessage = <String>[];
        final stat = DecompressStat();
        HashBundle? hb;
        if (options.hashMethods.isNotEmpty) {
          hb = HashBundle()..setMethods(options.hashMethods);
        }
        try {
          extract(
              codecs,
              types,
              excludedFormats,
              arcPathsSorted,
              arcPathsFullSorted,
              options.censor.pairs.first.head,
              eo,
              ecs,
              hb,
              errorMessage,
              stat);
        } on SystemException catch (e) {
          hresultMain = e.errorCode;
        }
        ecs.closePercents();

        if (errorMessage.isNotEmpty) {
          gErrStream?.write('\nERROR:\n${errorMessage.join('\n')}\n');
          if (hresultMain == HRes.sOk) hresultMain = HRes.eFail;
        }

        final so = gStdStream;
        var isError = false;
        if (so != null) {
          so.endl();
          if (ecs.numTryArcs > 1) {
            so.write('Archives: ${ecs.numTryArcs}\n');
            so.write('OK archives: ${ecs.numOkArcs}\n');
          }
        }
        if (ecs.numCantOpenArcs != 0) {
          isError = true;
          so?.write("Can't open as archive: ${ecs.numCantOpenArcs}\n");
        }
        if (ecs.numArcsWithError != 0) {
          isError = true;
          so?.write('Archives with Errors: ${ecs.numArcsWithError}\n');
        }
        if (so != null) {
          if (ecs.numArcsWithWarnings != 0) {
            so.write('Archives with Warnings: ${ecs.numArcsWithWarnings}\n');
          }
          if (ecs.numOpenArcWarnings != 0) {
            so.endl();
            so.write('Warnings: ${ecs.numOpenArcWarnings}\n');
          }
        }
        if (ecs.numOpenArcErrors != 0) {
          isError = true;
          if (so != null) {
            so.endl();
            so.write('Open Errors: ${ecs.numOpenArcErrors}\n');
          }
        }
        if (isError) retCode = ExitCode.fatalError;

        if (so != null) {
          if (ecs.numArcsWithError != 0 || ecs.numFileErrors != 0) {
            so.endl();
            if (ecs.numFileErrors != 0) {
              so.write('Sub items Errors: ${ecs.numFileErrors}\n');
            }
          } else if (hresultMain == HRes.sOk) {
            if (stat.numFolders != 0) so.write('Folders: ${stat.numFolders}\n');
            if (stat.numFiles != 1 ||
                stat.numFolders != 0 ||
                stat.numAltStreams != 0) {
              so.write('Files: ${stat.numFiles}\n');
            }
            if (stat.numAltStreams != 0) {
              so.write('Alternate Streams: ${stat.numAltStreams}\n');
              so.write(
                  'Alternate Streams Size: ${stat.altStreamsUnpackSize}\n');
            }
            so.write('Size:       ${stat.unpackSize}\n');
            so.write('Compressed: ${stat.packSize}\n');
            if (hb != null) {
              so.endl();
              printHashStat(so, hb);
            }
          }
        }
      } else {
        final lo = ListOptions()
          ..excludeDirItems = options.censor.excludeDirItems
          ..excludeFileItems = options.censor.excludeFileItems
          ..disablePercents = options.disablePercents;
        final (res, numErrors, numWarnings) = listArchives(
            lo,
            codecs,
            types,
            excludedFormats,
            options.stdInMode,
            arcPathsSorted,
            arcPathsFullSorted,
            options.extractOptions.ntOptions.altStreams.val,
            options.altStreams.val,
            options.censor.pairs.first.head,
            options.enableHeaders,
            options.techMode,
            options.passwordEnabled,
            options.password,
            options.properties);
        hresultMain = res;
        if (options.enableHeaders) {
          if (numWarnings > 0) gStdOut.write('\nWarnings: $numWarnings\n');
        }
        if (numErrors > 0) {
          if (options.enableHeaders) gStdOut.write('\nErrors: $numErrors\n');
          retCode = ExitCode.fatalError;
        }
      }
    }
  } else if (options.command.isFromUpdateGroup()) {
    final uo = options.updateOptions;
    final openCallback = OpenCallbackConsole();
    openCallback.init(gStdStream, gErrStream, percentsStream,
        options.disablePercents, gStdIn);
    final passwordIsDefined =
        options.passwordEnabled && options.password.isNotEmpty;
    openCallback.passwordIsDefined = passwordIsDefined;
    openCallback.password = options.password;

    final callback = UpdateCallbackConsole();
    callback.base.logLevel = options.logLevel;
    callback.base.percentsNameLevel = percentsNameLevel;
    if (percentsStream != null) callback.base.setWindowWidth(consoleWidth);
    callback.passwordIsDefined = passwordIsDefined;
    callback.askPassword = options.passwordEnabled && options.password.isEmpty;
    callback.password = options.password;
    callback.base.stdOutMode = uo.stdOutMode;
    callback.init(gStdStream, gErrStream, percentsStream,
        options.disablePercents, gStdIn);

    final errorInfo = UpdateErrorInfo();
    try {
      updateArchive(codecs, types, options.archiveName, options.censor, uo,
          errorInfo, openCallback, callback, true);
    } on SystemException catch (e) {
      hresultMain = e.errorCode;
    }
    callback.base.closePercents2();
    final se = gStdStream ?? gErrStream;
    retCode = _warningsCheck(
        hresultMain, callback.base, errorInfo, gStdStream, se, true);
  } else if (options.command.commandType == CommandType.hash) {
    final uo = options.hashOptions;
    final callback = HashCallbackConsole();
    if (percentsStream != null) callback.setWindowWidth(consoleWidth);
    callback.init(
        gStdStream, gErrStream, percentsStream, options.disablePercents);
    callback.printHeaders = options.enableHeaders;
    callback.printFields = options.listFields;
    final errorInfoString = <String>[];
    try {
      hashCalc(options.censor, uo, errorInfoString, callback,
          options.stdInMode ? gStdIn.dataStream : null);
    } on SystemException catch (e) {
      hresultMain = e.errorCode;
    }
    final errorInfo = UpdateErrorInfo()..message = errorInfoString.join();
    final se = gStdStream ?? gErrStream;
    retCode = _warningsCheck(hresultMain, callback, errorInfo, gStdStream, se,
        options.enableHeaders);
  } else {
    gErrStream?.write('\nERROR: $_kUserErrorMessage\n');
    throw const ExitCodeException(ExitCode.userError);
  }

  if (options.showTime && gStdStream != null) _printStat(startTime);
  throwIfError(hresultMain);
  return retCode;
}

// FlushStreams
void _flushStreams() => gStdStream?.flush();

// PrintError
void _printError(String message) {
  _flushStreams();
  gErrStream?.write('\n\n$message\n');
}

/// Runs the 7zr program with [args] (without the program name) on [io].
/// Returns the exit code (0, 1, 2, 7, 8 or 255, as 7-Zip).
int runSevenZipCliSync(List<String> args, CliIo io) {
  gIo = io;
  gStdOut = StdOutStream(io.writeOut, buffered: true, flush: io.flushOut);
  gStdErr = StdOutStream(io.writeErr, buffered: false);
  gStdStream = gStdOut;
  gErrStream = gStdErr;
  gStdIn = StdInStream(io.stdinStream);
  gSetEcho = io.setEcho;
  gCaseSensitive = defaultCaseSensitive();
  gTimestampShowUtc = false;
  gPathTrailReplaceMode = kIsWin;
  cliCurrentDirectory = io.workingDirectory;

  var res = 0;
  try {
    res = _main2(args, io);
  } on OutOfMemoryError {
    _printError("ERROR: Can't allocate required memory!");
    res = ExitCode.memoryError;
  } on MessagePathException catch (e) {
    _printError('Command Line Error:');
    gErrStream?.write('${e.message}\n');
    res = ExitCode.userError;
  } on SystemException catch (e) {
    if (e.errorCode == HRes.eOutOfMemory) {
      _printError("ERROR: Can't allocate required memory!");
      res = ExitCode.memoryError;
    } else if (e.errorCode == HRes.eAbort) {
      _printError('Break signaled');
      res = ExitCode.userBreak;
    } else {
      final es = gErrStream;
      if (es != null) {
        _printError('System ERROR:');
        es.write('${myFormatMessage(e.errorCode)}\n');
      }
      res = ExitCode.fatalError;
    }
  } on ExitCodeException catch (e) {
    _flushStreams();
    gErrStream?.write('\n\nInternal Error #${e.code}\n');
    res = e.code;
  } on StringException catch (e) {
    final es = gErrStream;
    if (es != null) {
      _printError('ERROR:');
      es.write('${e.message}\n');
    }
    res = ExitCode.fatalError;
  } on FileSystemException catch (e) {
    final es = gErrStream;
    if (es != null) {
      _printError('System ERROR:');
      es.write('${myFormatMessage(hresultOfFileSystemException(e))}\n');
    }
    res = ExitCode.fatalError;
  } on SevenZipException catch (e) {
    final es = gErrStream;
    if (es != null) {
      _printError('ERROR:');
      es.write('${e.message}\n');
    }
    res = ExitCode.fatalError;
  }
  gStdOut.flush();
  gStdErr.flush();
  return res;
}

/// The in-process entry for tests: [stdout] and [stderr] receive the bytes,
/// [stdin] gives the standard input.
Future<int> runSevenZipCli(List<String> args,
    {void Function(Uint8List bytes)? stdout,
    void Function(Uint8List bytes)? stderr,
    Uint8List? stdin,
    String? workingDirectory}) async {
  final io = CliIo(
    writeOut: stdout ?? (_) {},
    writeErr: stderr ?? (_) {},
    stdinStream: MemoryInStream(stdin ?? Uint8List(0)),
    workingDirectory: workingDirectory,
  );
  return runSevenZipCliSync(args, io);
}

/// Runs the program as the process: [args] without the program name,
/// returns the exit code. Linux and macOS run it here with the standard
/// streams of the process; Windows runs it in a worker isolate that sends
/// the output to this one (see [windowsWorkerCliIo]).
Future<int> runSevenZipCliProcess(List<String> args) async {
  if (!kIsWin) return runSevenZipCliSync(args, processCliIo());
  final port = ReceivePort();
  final done = Completer<int>();
  port.listen((Object? m) {
    if (m is (int, Object?)) {
      final (tag, data) = m;
      if (tag == 1) {
        stdout.add(data as Uint8List);
      } else if (tag == 2) {
        stderr.add(data as Uint8List);
      } else if (!done.isCompleted) {
        done.complete(data as int);
      }
    } else if (!done.isCompleted) {
      // the worker isolate ended without a result (onExit)
      done.complete(ExitCode.fatalError);
    }
  });
  await Isolate.spawn(_windowsWorker, (args, port.sendPort),
      onExit: port.sendPort, errorsAreFatal: true);
  final code = await done.future;
  port.close();
  await stdout.flush();
  await stderr.flush();
  return code;
}

void _windowsWorker((List<String>, SendPort) msg) {
  final (args, port) = msg;
  var code = ExitCode.fatalError;
  try {
    code = runSevenZipCliSync(args, windowsWorkerCliIo(port));
  } finally {
    port.send((0, code));
  }
}
