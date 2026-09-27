// The switches and commands of 7-Zip: UI/Common/ArchiveCommandLine.cpp of
// the LZMA SDK (CArcCmdLineParser::Parse1 / Parse2 with every switch of the
// console program).

import 'dart:io';

import 'archive_extract_callback.dart';
import 'command_line_parser.dart';
import 'common.dart';
import 'extract.dart';
import 'extracting_file_path.dart';
import 'fs_utils.dart' show resolvePath;
import 'hash_calc.dart';
import 'nest.dart' show kDefaultNestDepth;
import 'open_archive.dart' show parseComplexSize;
import 'prop_id_utils.dart';
import 'update.dart';
import 'update_pair.dart';
import 'wildcard.dart';
import 'platform.dart';

/// NCommandType.
enum CommandType {
  add,
  update,
  delete,
  test,
  extract,
  extractFull,
  list,
  benchmark,
  info,
  hash,
  rename
}

/// CArcCommand.
class ArcCommand {
  CommandType commandType = CommandType.add;

  bool isFromExtractGroup() =>
      commandType == CommandType.test ||
      commandType == CommandType.extract ||
      commandType == CommandType.extractFull;

  bool isFromUpdateGroup() =>
      commandType == CommandType.add ||
      commandType == CommandType.update ||
      commandType == CommandType.delete ||
      commandType == CommandType.rename;

  bool isTestCommand() => commandType == CommandType.test;

  PathMode getPathMode() =>
      (commandType == CommandType.test ||
              commandType == CommandType.extractFull)
          ? PathMode.fullPaths
          : PathMode.noPaths;
}

const int kOutStreamDisabled = 0;
const int kOutStreamStdout = 1;
const int kOutStreamStderr = 2;

/// CArcCmdLineOptions.
class ArcCmdLineOptions {
  bool helpMode = false;
  bool caseSensitiveChange = false;
  bool caseSensitive = false;
  bool isInTerminal = false;
  bool isStdOutTerminal = false;
  bool isStdErrTerminal = false;
  bool stdInMode = false;
  bool stdOutMode = false;
  bool enableHeaders = false;
  bool disablePercents = false;
  bool yesToAll = false;
  bool showDialog = false;
  bool techMode = false;
  bool showTime = false;

  /// -snest[N] (zx extension): the depth of the nested archives shown in
  /// one tree by l, t, x and e; 0 when off.
  int nestDepth = 0;
  final BoolPair2 listPathSeparatorSlash = BoolPair2(true);

  BoolPair2 ntSecurity = BoolPair2();
  BoolPair2 altStreams = BoolPair2();
  BoolPair2 hardLinks = BoolPair2();
  BoolPair2 symLinks = BoolPair2();
  BoolPair2 storeOwnerId = BoolPair2();
  BoolPair2 storeOwnerName = BoolPair2();

  String listFields = '';
  int consoleCodePage = -1;

  final Censor censor = Censor();
  final ArcCommand command = ArcCommand();
  String archiveName = '';

  bool passwordEnabled = false;
  String password = '';

  List<String> hashMethods = [];
  final Censor arcCensor = Censor();
  String arcNameForStdInMode = '';

  final List<MapEntry<String, String>> properties = [];

  final ExtractOptions extractOptions = ExtractOptions();
  final UpdateOptions updateOptions = UpdateOptions();
  final HashOptions hashOptions = HashOptions();
  String arcType = '';
  List<String> excludedArcTypes = [];

  int numberForOut = kOutStreamStdout;
  int numberForErrors = kOutStreamStderr;
  int numberForPercents = kOutStreamStdout;
  int logLevel = 0;

  int numIterations = 1;
  bool numIterationsDefined = false;
}

/// NKey.
abstract final class _K {
  static const help1 = 0;
  static const help2 = 1;
  static const help3 = 2;
  static const disableHeaders = 3;
  static const disablePercents = 4;
  static const showTime = 5;
  static const logLevel = 6;
  static const outStream = 7;
  static const errStream = 8;
  static const percentStream = 9;
  static const yes = 10;
  static const showDialog = 11;
  static const overwrite = 12;
  static const archiveType = 13;
  static const excludedArcType = 14;
  static const property = 15;
  static const outputDir = 16;
  static const workingDir = 17;
  static const include = 18;
  static const exclude = 19;
  static const arInclude = 20;
  static const arExclude = 21;
  static const noArName = 22;
  static const update = 23;
  static const volume = 24;
  static const recursed = 25;
  static const affinity = 26;
  static const sfx = 27;
  static const email = 28;
  static const hash = 29;
  static const hashDir = 30;
  static const extractMemLimit = 31;
  static const stdIn = 32;
  static const stdOut = 33;
  static const largePages = 34;
  static const listfileCharSet = 35;
  static const consoleCharSet = 36;
  static const techMode = 37;
  static const listFields = 38;
  static const listPathSlash = 39;
  static const listTimestampUTC = 40;
  static const preserveATime = 41;
  static const shareForWrite = 42;
  static const stopAfterOpenError = 43;
  static const caseSensitive = 44;
  static const arcNameMode = 45;
  static const useSlashMark = 46;
  static const disableWildcardParsing = 47;
  static const elimDup = 48;
  static const fullPathMode = 49;
  static const outDirMode = 50;
  static const hardLinks = 51;
  static const symLinksAllowDangerous = 52;
  static const symLinks = 53;
  static const ntSecurity = 54;
  static const storeOwnerId = 55;
  static const storeOwnerName = 56;
  static const zoneFile = 57;
  static const altStreams = 58;
  static const replaceColonForAltStream = 59;
  static const writeToAltStreamIfColon = 60;
  static const nameTrailReplace = 61;
  static const deleteAfterCompressing = 62;
  static const setArcMTime = 63;
  static const password = 64;
  static const nest = 65;
}

const String _kRecursedPostCharSet = '0-';
const String _kArcNameModePostCharSet = 'sea';
const String _kStreamPostCharSet = '012';
const int _kSomeCludePostStringMinSize = 2;
const int _kSomeCludeAfterRecursedPostStringMinSize = 2;
const String _kOverwritePostCharSet = 'asut';

const List<OverwriteMode> _kOverwriteModes = [
  OverwriteMode.overwrite,
  OverwriteMode.skip,
  OverwriteMode.rename,
  OverwriteMode.renameExisting,
];

SwitchForm _simple(String k) => SwitchForm(k, SwitchType.simple);
SwitchForm _minus(String k) => SwitchForm(k, SwitchType.minus);
SwitchForm _string(String k) => SwitchForm(k, SwitchType.string);
SwitchForm _stringSingl(String k, int mi) =>
    SwitchForm(k, SwitchType.string, false, mi);
SwitchForm _stringMult(String k, int mi) =>
    SwitchForm(k, SwitchType.string, true, mi);

final List<SwitchForm> _kSwitchForms = [
  _simple('?'),
  _simple('h'),
  _simple('-help'),
  _simple('ba'),
  _simple('bd'),
  _simple('bt'),
  _stringSingl('bb', 0),
  const SwitchForm('bso', SwitchType.char, false, 1, _kStreamPostCharSet),
  const SwitchForm('bse', SwitchType.char, false, 1, _kStreamPostCharSet),
  const SwitchForm('bsp', SwitchType.char, false, 1, _kStreamPostCharSet),
  _simple('y'),
  _simple('ad'),
  const SwitchForm('ao', SwitchType.char, false, 1, _kOverwritePostCharSet),
  _stringSingl('t', 1),
  _stringMult('stx', 1),
  _stringMult('m', 1),
  _stringSingl('o', 1),
  _string('w'),
  _stringMult('i', _kSomeCludePostStringMinSize),
  _stringMult('x', _kSomeCludePostStringMinSize),
  _stringMult('ai', _kSomeCludePostStringMinSize),
  _stringMult('ax', _kSomeCludePostStringMinSize),
  _simple('an'),
  _stringMult('u', 1),
  _stringMult('v', 1),
  const SwitchForm('r', SwitchType.char, false, 0, _kRecursedPostCharSet),
  _string('stm'),
  _string('sfx'),
  _stringSingl('seml', 0),
  _stringMult('scrc', 0),
  _stringSingl('shd', 1),
  _string('smemx'),
  _string('si'),
  _simple('so'),
  _string('slp'),
  _string('scs'),
  _string('scc'),
  _simple('slt'),
  _stringSingl('slf', 1),
  _minus('slsl'),
  _minus('slmu'),
  _simple('ssp'),
  _simple('ssw'),
  _simple('sse'),
  _minus('ssc'),
  const SwitchForm('sa', SwitchType.char, false, 1, _kArcNameModePostCharSet),
  _stringSingl('spm', 0),
  _simple('spd'),
  _minus('spe'),
  _stringSingl('spf', 0),
  const SwitchForm('spo', SwitchType.char, false, 1, 'dcr'),
  _minus('snh'),
  _string('snld'),
  _minus('snl'),
  _simple('sni'),
  _minus('snoi'),
  _minus('snon'),
  _stringSingl('snz', 0),
  _minus('sns'),
  _simple('snr'),
  _simple('snc'),
  _minus('snt'),
  _simple('sdel'),
  _simple('stl'),
  _string('p'),
  // zx extension: flatten nested archives (nest.dart)
  _stringSingl('snest', 0),
];

const String _kUniversalWildcard = '*';
const int _kMinNonSwitchWords = 1;
const int _kCommandIndex = 0;

const String _kIncorrectListFile =
    'Incorrect item in listfile.\nCheck charset encoding and -scs switch.';
const String _kTerminalOutError = "I won't write compressed data to a terminal";
const String _kSameTerminalError =
    "I won't write data and program's messages to same stream";
const String _kEmptyFilePath = 'Empty file path';

// StringToUInt32
int? _stringToUInt32(String s) {
  if (s.isEmpty) return null;
  var v = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return null;
    v = v * 10 + (c - 0x30);
    if (v > 0xFFFFFFFF) return null;
  }
  return v;
}

// GetRecursedTypeFromIndex
RecursedType _getRecursedTypeFromIndex(int index) {
  switch (index) {
    case 0:
      return RecursedType.wildcardOnlyRecursed;
    case 1:
      return RecursedType.nonRecursed;
    default:
      return RecursedType.recursed;
  }
}

const String _gCommands = 'audtexlbih';

// ParseArchiveCommand
bool _parseArchiveCommand(String commandString, ArcCommand command) {
  final s = commandString.toLowerCase();
  if (s.length == 1) {
    if (s.codeUnitAt(0) > 0x7F) return false;
    final index = _gCommands.indexOf(s);
    if (index < 0) return false;
    command.commandType = CommandType.values[index];
    return true;
  }
  if (s == 'rn') {
    command.commandType = CommandType.rename;
    return true;
  }
  return false;
}

/// CNameOption.
class _NameOption {
  bool include = true;
  bool wildcardMatching = true;
  int markMode = kMarkFileOrDir;
  RecursedType recursedType = RecursedType.nonRecursed;

  _NameOption copy() => _NameOption()
    ..include = include
    ..wildcardMatching = wildcardMatching
    ..markMode = markMode
    ..recursedType = recursedType;
}

// AddNameToCensor
void _addNameToCensor(Censor censor, _NameOption nop, String name) {
  var recursed = false;
  switch (nop.recursedType) {
    case RecursedType.wildcardOnlyRecursed:
      recursed = doesNameContainWildcard(name);
    case RecursedType.recursed:
      recursed = true;
    case RecursedType.nonRecursed:
      break;
  }
  final props = CensorPathProps()
    ..recursive = recursed
    ..wildcardMatching = nop.wildcardMatching
    ..markMode = nop.markMode;
  censor.addPreItem(nop.include, name, props);
}

// AddRenamePair
void _addRenamePair(List<RenamePair> renamePairs, String oldName,
    String newName, RecursedType type, bool wildcardMatching) {
  final pair = RenamePair()
    ..oldName = oldName
    ..newName = newName
    ..recursedType = type
    ..wildcardParsing = wildcardMatching;
  renamePairs.add(pair);
  if (!pair.prepare()) {
    var val = '${pair.oldName}\n${pair.newName}\n';
    if (type == RecursedType.recursed) {
      val += '-r';
    } else if (type == RecursedType.wildcardOnlyRecursed) {
      val += '-r0';
    }
    throw MessagePathException('Unsupported rename command:', val);
  }
}

// AddToCensorFromListFile
void _addToCensorFromListFile(List<RenamePair>? renamePairs, Censor censor,
    _NameOption nop, String fileName, int codePage) {
  final r = readNamesFromListFile2(resolvePath(fileName), codePage);
  final names = r.names;
  if (names == null) {
    if (r.lastError != 0) {
      noteErrnoMessage(r.lastError, r.osMessage);
      final m =
          'The file operation error for listfile\n${myFormatMessage(r.lastError)}';
      throw MessagePathException(m, fileName);
    }
    throw MessagePathException(_kIncorrectListFile, fileName);
  }
  if (renamePairs != null) {
    if ((names.length & 1) != 0) {
      throw MessagePathException(_kIncorrectListFile, fileName);
    }
    for (var i = 0; i < names.length; i += 2) {
      _addRenamePair(renamePairs, names[i], names[i + 1], nop.recursedType,
          nop.wildcardMatching);
    }
  } else {
    for (final n in names) {
      _addNameToCensor(censor, nop, n);
    }
  }
}

// AddToCensorFromNonSwitchesStrings
void _addToCensorFromNonSwitchesStrings(
    List<RenamePair>? renamePairs,
    int startIndex,
    Censor censor,
    List<String> nonSwitchStrings,
    int stopSwitchIndex,
    _NameOption nop,
    bool thereAreSwitchIncludes,
    int codePage) {
  if ((renamePairs != null || nonSwitchStrings.length == startIndex) &&
      !thereAreSwitchIncludes) {
    _addNameToCensor(censor, _NameOption(), _kUniversalWildcard);
  }
  var oldIndex = -1;
  if (stopSwitchIndex < 0) stopSwitchIndex = nonSwitchStrings.length;
  for (var i = startIndex; i < nonSwitchStrings.length; i++) {
    final s = nonSwitchStrings[i];
    if (s.isEmpty) throw MessagePathException(_kEmptyFilePath);
    if (i < stopSwitchIndex && s.startsWith('@')) {
      _addToCensorFromListFile(
          renamePairs, censor, nop, s.substring(1), codePage);
    } else if (renamePairs != null) {
      if (oldIndex == -1) {
        oldIndex = i;
      } else {
        _addRenamePair(renamePairs, nonSwitchStrings[oldIndex], s,
            RecursedType.nonRecursed, nop.wildcardMatching);
        oldIndex = -1;
      }
    } else {
      _addNameToCensor(censor, nop, s);
    }
  }
  if (oldIndex != -1) {
    throw MessagePathException('There is no second file name for rename pair:',
        nonSwitchStrings[oldIndex]);
  }
}

// AddSwitchWildcardsToCensor
void _addSwitchWildcardsToCensor(
    Censor censor, List<String> strings, _NameOption nop, int codePage) {
  String? errorMessage;
  var i = 0;
  for (; i < strings.length; i++) {
    final name = strings[i];
    var pos = 0;
    if (name.length < _kSomeCludePostStringMinSize) {
      errorMessage = 'Too short switch';
      break;
    }
    if (!nop.include) {
      if (name.toLowerCase() == 'td') {
        censor.excludeDirItems = true;
        continue;
      }
      if (name.toLowerCase() == 'tf') {
        censor.excludeFileItems = true;
        continue;
      }
    }
    final nop2 = nop.copy();
    var typeWasUsed = false;
    var recursedWasUsed = false;
    var matchingWasUsed = false;
    var error = false;
    String at(int p) => p < name.length ? name[p] : '';

    for (;;) {
      var c = at(pos).toLowerCase();
      if (c == 'r') {
        if (recursedWasUsed) {
          error = true;
          break;
        }
        recursedWasUsed = true;
        pos++;
        c = at(pos);
        var index = -1;
        if (c.isNotEmpty && c.codeUnitAt(0) <= 0x7F) {
          index = _kRecursedPostCharSet.indexOf(c);
        }
        nop2.recursedType = _getRecursedTypeFromIndex(index);
        if (index >= 0) {
          pos++;
          continue;
        }
      }
      if (c == 'w') {
        if (matchingWasUsed) {
          error = true;
          break;
        }
        matchingWasUsed = true;
        nop2.wildcardMatching = true;
        pos++;
        if (at(pos) == '-') {
          nop2.wildcardMatching = false;
          pos++;
        }
      } else if (c == 'm') {
        if (typeWasUsed) {
          error = true;
          break;
        }
        typeWasUsed = true;
        pos++;
        nop2.markMode = kMarkStrictFile;
        c = at(pos);
        if (c == '-') {
          nop2.markMode = kMarkFileOrDir;
          pos++;
        } else if (c == '2') {
          nop2.markMode = kMarkStrictFileIfWildcard;
          pos++;
        }
      } else {
        break;
      }
    }
    if (error) {
      errorMessage = 'inorrect switch';
      break;
    }
    if (name.length < pos + _kSomeCludeAfterRecursedPostStringMinSize) {
      errorMessage = 'Too short switch';
      break;
    }
    final tail = name.substring(pos + 1);
    final c = name[pos];
    if (c == '!') {
      _addNameToCensor(censor, nop2, tail);
    } else if (c == '@') {
      _addToCensorFromListFile(null, censor, nop2, tail, codePage);
    } else if (kIsWin && c == '#') {
      errorMessage = _parseMapWithPaths(tail);
      if (errorMessage != null) break;
    } else {
      errorMessage = 'Incorrect wildcard type marker';
      break;
    }
  }
  if (i != strings.length) {
    throw MessagePathException(errorMessage!, strings[i]);
  }
}

// ParseMapWithPaths (_WIN32): the names are in a named file mapping of
// the 7-Zip GUI, which dart:io can not open, so a correct command ends
// with the error of a failing OpenFileMapping.
String? _parseMapWithPaths(String s) {
  const kIncorrectMapCommand = 'Incorrect Map command';
  final pos = s.indexOf(':');
  if (pos < 0) return kIncorrectMapCommand;
  final pos2 = s.indexOf(':', pos + 1);
  if (pos2 < 0) return kIncorrectMapCommand;
  final size = _stringToUInt32(s.substring(pos + 1, pos2));
  if (size == null || size < 2 || size > (1 << 31) || size % 2 != 0) {
    return 'Unsupported Map data size';
  }
  return 'Cannot open mapping';
}

// ParseUpdateCommandString2: (ok, postString)
(bool, String) _parseUpdateCommandString2(String command, ActionSet actionSet) {
  const kUpdatePairStateIDSet = 'pqrxyzw';
  const kUpdatePairStateNotSupportedActions = [2, 2, 1, -1, -1, -1, -1];
  const kNumUpdatePairActions = 4;
  var i = 0;
  while (i < command.length) {
    final c = command[i].toLowerCase();
    final statePos = kUpdatePairStateIDSet.indexOf(c);
    if (c.codeUnitAt(0) > 0x7F || statePos < 0) {
      return (true, command.substring(i));
    }
    i++;
    if (i >= command.length) return (false, '');
    final d = command.codeUnitAt(i);
    if (d < 0x30 || d >= 0x30 + kNumUpdatePairActions) return (false, '');
    final actionPos = d - 0x30;
    actionSet.stateActions[statePos] = actionPos;
    if (kUpdatePairStateNotSupportedActions[statePos] == actionPos) {
      return (false, '');
    }
    i++;
  }
  return (true, '');
}

// ParseUpdateCommandString
void _parseUpdateCommandString(UpdateOptions options,
    List<String> updatePostStrings, ActionSet defaultActionSet) {
  const errorMessage = 'incorrect update switch command';
  var i = 0;
  for (; i < updatePostStrings.length; i++) {
    final updateString = updatePostStrings[i];
    if (updateString == '-') {
      if (options.updateArchiveItself) {
        options.updateArchiveItself = false;
        options.commands.removeAt(0);
      }
    } else {
      final actionSet = defaultActionSet.copy();
      final (ok, postString) = _parseUpdateCommandString2(updateString, actionSet);
      if (!ok) break;
      if (postString.isEmpty) {
        if (options.updateArchiveItself) {
          options.commands[0].actionSet = actionSet;
        }
      } else {
        if (!postString.startsWith('!')) break;
        final archivePath = postString.substring(1);
        if (archivePath.isEmpty) break;
        options.commands.add(UpdateArchiveCommand()
          ..userArchivePath = archivePath
          ..actionSet = actionSet);
      }
    }
  }
  if (i != updatePostStrings.length) {
    throw MessagePathException(errorMessage, updatePostStrings[i]);
  }
}

// SetAddCommandOptions
void _setAddCommandOptions(
    CommandType commandType, CommandLineParser parser, UpdateOptions options) {
  ActionSet defaultActionSet;
  switch (commandType) {
    case CommandType.add:
      defaultActionSet = kActionSetAdd();
    case CommandType.delete:
      defaultActionSet = kActionSetDelete();
    default:
      defaultActionSet = kActionSetUpdate();
  }
  options.updateArchiveItself = true;
  options.commands.clear();
  options.commands.add(UpdateArchiveCommand()..actionSet = defaultActionSet);
  if (parser[_K.update].thereIs) {
    _parseUpdateCommandString(
        options, parser[_K.update].postStrings, defaultActionSet);
  }
  if (parser[_K.workingDir].thereIs) {
    final postString = parser[_K.workingDir].postStrings[0];
    if (postString.isEmpty) {
      options.workingDir = normalizeDirPathPrefix(Directory.systemTemp.path);
    } else {
      options.workingDir = postString;
    }
  }
  options.sfxMode = parser[_K.sfx].thereIs;
  if (options.sfxMode) options.sfxModule = parser[_K.sfx].postStrings[0];

  if (parser[_K.volume].thereIs) {
    final sv = parser[_K.volume].postStrings;
    for (var i = 0; i < sv.length; i++) {
      final size = parseComplexSize(sv[i]);
      if (size == null) {
        throw MessagePathException('Incorrect volume size:', sv[i]);
      }
      if (i == sv.length - 1 && size == 0) {
        throw MessagePathException('zero size last volume is not allowed');
      }
      options.volumesSizes.add(size);
    }
  }
}

// SetMethodOptions
void _setMethodOptions(
    CommandLineParser parser, List<MapEntry<String, String>> properties) {
  if (parser[_K.property].thereIs) {
    for (final s in parser[_K.property].postStrings) {
      final index = s.indexOf('=');
      if (index >= 0) {
        properties.add(MapEntry(s.substring(0, index), s.substring(index + 1)));
      } else {
        properties.add(MapEntry(s, ''));
      }
    }
  }
}

const List<(String, int)> _gCodePagePairs = [
  ('utf-8', CodePage.utf8),
  ('win', CodePage.acp),
  ('dos', CodePage.oemcp),
  ('utf-16le', CodePage.utf16),
  ('utf-16be', CodePage.utf16be),
];

// FindCharset
int _findCharset(CommandLineParser parser, int keyIndex, bool byteOnlyCodePages,
    int defaultVal) {
  if (!parser[keyIndex].thereIs) return defaultVal;
  var name = parser[keyIndex].postStrings.last;
  final v = _stringToUInt32(name);
  if (v != null && v < (1 << 16)) return v;
  name = name.toLowerCase();
  final num = byteOnlyCodePages ? 3 : _gCodePagePairs.length;
  for (var i = 0;; i++) {
    if (i == num) throw MessagePathException('Unsupported charset:', name);
    if (name == _gCodePagePairs[i].$1) return _gCodePagePairs[i].$2;
  }
}

// SetBoolPair
void _setBoolPair(CommandLineParser parser, int switchId, BoolPair2 bp) {
  bp.def = parser[switchId].thereIs;
  if (bp.def) bp.val = !parser[switchId].withMinus;
}

// ParseSizeString (ArchiveCommandLine.cpp)
int? _parseSizeString(String s) {
  var i = 0;
  var v = 0;
  for (; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) break;
    v = v * 10 + (c - 0x30);
  }
  if (i == 0) return null;
  if (i == s.length) return v;
  if (i + 1 != s.length) return null;
  int numBits;
  switch (s[i].toLowerCase()) {
    case 'b':
      numBits = 0;
    case 'k':
      numBits = 10;
    case 'm':
      numBits = 20;
    case 'g':
      numBits = 30;
    case 't':
      numBits = 40;
    default:
      return null;
  }
  final val2 = v << numBits;
  if ((val2 >>> numBits) != v) return null;
  return val2;
}

/// CArcCmdLineParser.
class ArcCmdLineParser {
  final CommandLineParser parser = CommandLineParser();
  String parse1Log = '';

  /// Parse1: [isStdinTerminal] etc. come from the process.
  void parse1(List<String> commandStrings, ArcCmdLineOptions options,
      {required bool stdinTerminal,
      required bool stdoutTerminal,
      required bool stderrTerminal}) {
    parse1Log = '';
    if (!parser.parseStrings(_kSwitchForms, commandStrings)) {
      throw MessagePathException(parser.errorMessage, parser.errorLine);
    }
    options.isInTerminal = stdinTerminal;
    options.isStdOutTerminal = stdoutTerminal;
    options.isStdErrTerminal = stderrTerminal;

    options.helpMode = parser[_K.help1].thereIs ||
        parser[_K.help2].thereIs ||
        parser[_K.help3].thereIs;
    options.yesToAll = parser[_K.yes].thereIs;
    options.stdInMode = parser[_K.stdIn].thereIs;
    options.stdOutMode = parser[_K.stdOut].thereIs;
    options.enableHeaders = !parser[_K.disableHeaders].thereIs;
    if (parser[_K.listFields].thereIs) {
      options.listFields = parser[_K.listFields].postStrings[0];
    }
    if (parser[_K.listPathSlash].thereIs) {
      options.listPathSeparatorSlash.val = !parser[_K.listPathSlash].withMinus;
      options.listPathSeparatorSlash.def = true;
    }
    if (parser[_K.listTimestampUTC].thereIs) {
      gTimestampShowUtc = !parser[_K.listTimestampUTC].withMinus;
    }
    options.techMode = parser[_K.techMode].thereIs;
    if (parser[_K.nest].thereIs) {
      final s = parser[_K.nest].postStrings.isEmpty
          ? ''
          : parser[_K.nest].postStrings.first;
      final n = s.isEmpty ? kDefaultNestDepth : _stringToUInt32(s);
      if (n == null || n < 1 || n > 32) {
        throw MessagePathException('Unsupported switch postfix -snest', s);
      }
      options.nestDepth = n;
    }
    options.showTime = parser[_K.showTime].thereIs;

    if (parser[_K.disablePercents].thereIs) options.disablePercents = true;
    if (parser[_K.disablePercents].thereIs ||
        options.stdOutMode ||
        !options.isStdOutTerminal) {
      options.numberForPercents = kOutStreamDisabled;
    }
    if (options.stdOutMode) options.numberForOut = kOutStreamDisabled;

    if (parser[_K.outStream].thereIs) {
      options.numberForOut = parser[_K.outStream].postCharIndex;
    }
    if (parser[_K.errStream].thereIs) {
      options.numberForErrors = parser[_K.errStream].postCharIndex;
    }
    if (parser[_K.percentStream].thereIs) {
      options.numberForPercents = parser[_K.percentStream].postCharIndex;
    }

    if (parser[_K.logLevel].thereIs) {
      final s = parser[_K.logLevel].postStrings[0];
      if (s.isEmpty) {
        options.logLevel = 1;
      } else {
        final v = _stringToUInt32(s);
        if (v == null) {
          throw MessagePathException('Unsupported switch postfix -bb', s);
        }
        options.logLevel = v;
      }
    }

    if (parser[_K.caseSensitive].thereIs) {
      options.caseSensitive =
          gCaseSensitive = !parser[_K.caseSensitive].withMinus;
      options.caseSensitiveChange = true;
    }

    if (parser[_K.largePages].thereIs) {
      // the options are checked; large pages are not used by the port
      final s = parser[_K.largePages].postStrings[0];
      if (s != '-' && s.isNotEmpty) {
        var index = 0;
        while (index < s.length) {
          final isStart = index == 0;
          String s2;
          final pos = s.indexOf(':', index);
          if (pos < 0) {
            s2 = s.substring(index);
            index = s.length;
          } else {
            s2 = s.substring(index, pos);
            index = pos + 1;
          }
          if (s2.isEmpty) continue;
          final l = s2.toLowerCase();
          if (isStart) {
            if (_stringToUInt32(s2) != null) continue;
          } else if (l.startsWith('ps')) {
            final ps = _stringToUInt32(s2.substring(2));
            if (ps != null && ps < 64) continue;
          } else if (l.startsWith('min')) {
            final ps = _stringToUInt32(s2.substring(3));
            if (ps != null && ps < 64) continue;
          } else if (l == 'failstop' || l == 'nomadvise' || l == 'nohuge') {
            continue;
          }
          throw MessagePathException('Unsupported switch postfix for -slp', s);
        }
      }
    }

    if (parser[_K.affinity].thereIs) {
      final s = parser[_K.affinity].postStrings[0];
      if (s.isNotEmpty) {
        // the affinity can not be set from Dart: the value is checked and
        // logged as the SDK does
        var isError = false;
        for (final c in s.codeUnits) {
          final isHex = (c >= 0x30 && c <= 0x39) ||
              (c >= 0x41 && c <= 0x46) ||
              (c >= 0x61 && c <= 0x66);
          if (!isHex) isError = true;
        }
        var logValue = s;
        if (kIsWin) {
          // ConvertHexStringToUInt64 and PrintHex: at most 16 digits
          isError = isError || s.length > 16;
          if (!isError) {
            var v = 0;
            for (final c in s.codeUnits) {
              v = (v << 4) | ((c <= 0x39) ? c - 0x30 : (c | 0x20) - 0x61 + 10);
            }
            logValue = hexUpper(v);
          }
        }
        if (isError) {
          throw MessagePathException('Unsupported switch postfix -stm', s);
        }
        parse1Log += 'Set process affinity mask: $logValue\n';
      }
    }
  }

  /// Parse2.
  void parse2(ArcCmdLineOptions options) {
    final nonSwitchStrings = parser.nonSwitchStrings;
    final numNonSwitchStrings = nonSwitchStrings.length;
    if (numNonSwitchStrings < _kMinNonSwitchWords) {
      throw MessagePathException('The command must be specified');
    }
    if (!_parseArchiveCommand(nonSwitchStrings[_kCommandIndex], options.command)) {
      throw MessagePathException(
          'Unsupported command:', nonSwitchStrings[_kCommandIndex]);
    }

    if (parser[_K.hash].thereIs) {
      options.hashMethods = List.of(parser[_K.hash].postStrings);
    }
    if (parser[_K.hashDir].thereIs) {
      options.extractOptions.hashDir = parser[_K.hashDir].postStrings[0];
    }
    if (parser[_K.extractMemLimit].thereIs) {
      final s = parser[_K.extractMemLimit].postStrings[0];
      final v = _parseSizeString(s);
      if (v == null) throw MessagePathException('Unsupported -smemx:', s);
      options.extractOptions.ntOptions.memLimit = v;
    }
    if (parser[_K.elimDup].thereIs) {
      options.extractOptions.elimDup.def = true;
      options.extractOptions.elimDup.val = !parser[_K.elimDup].withMinus;
    }

    var censorPathMode = CensorPathMode.relatPath;
    final fullPathMode = parser[_K.fullPathMode].thereIs;
    if (fullPathMode) {
      censorPathMode = CensorPathMode.absPath;
      final s = parser[_K.fullPathMode].postStrings[0];
      if (s.isNotEmpty) {
        if (s == '2') {
          censorPathMode = CensorPathMode.fullPath;
        } else {
          throw MessagePathException('Unsupported -spf:', s);
        }
      }
    }

    if (parser[_K.nameTrailReplace].thereIs) {
      gPathTrailReplaceMode = !parser[_K.nameTrailReplace].withMinus;
    }

    final nop = _NameOption();
    if (parser[_K.recursed].thereIs) {
      nop.recursedType =
          _getRecursedTypeFromIndex(parser[_K.recursed].postCharIndex);
    }
    if (parser[_K.disableWildcardParsing].thereIs) nop.wildcardMatching = false;
    if (parser[_K.useSlashMark].thereIs) {
      final s = parser[_K.useSlashMark].postStrings[0];
      if (s.isEmpty) {
        nop.markMode = kMarkStrictFile;
      } else if (s.toLowerCase() == '-') {
        nop.markMode = kMarkFileOrDir;
      } else if (s.toLowerCase() == '2') {
        nop.markMode = kMarkStrictFileIfWildcard;
      } else {
        throw MessagePathException('Unsupported -spm:', s);
      }
    }

    options.consoleCodePage = _findCharset(parser, _K.consoleCharSet, true, -1);
    final codePage =
        _findCharset(parser, _K.listfileCharSet, false, CodePage.utf8);

    var thereAreSwitchIncludes = false;
    if (parser[_K.include].thereIs) {
      thereAreSwitchIncludes = true;
      nop.include = true;
      _addSwitchWildcardsToCensor(
          options.censor, parser[_K.include].postStrings, nop, codePage);
    }
    if (parser[_K.exclude].thereIs) {
      nop.include = false;
      _addSwitchWildcardsToCensor(
          options.censor, parser[_K.exclude].postStrings, nop, codePage);
    }

    var curCommandIndex = _kCommandIndex + 1;
    var thereIsArchiveName = !parser[_K.noArName].thereIs &&
        options.command.commandType != CommandType.benchmark &&
        options.command.commandType != CommandType.info &&
        options.command.commandType != CommandType.hash;

    final isExtractGroupCommand = options.command.isFromExtractGroup();
    final isExtractOrList =
        isExtractGroupCommand || options.command.commandType == CommandType.list;
    final isRename = options.command.commandType == CommandType.rename;
    options.updateOptions.renameMode = isRename;

    if ((isExtractOrList || isRename) && options.stdInMode) {
      thereIsArchiveName = false;
    }

    if (parser[_K.arcNameMode].thereIs) {
      final i = parser[_K.arcNameMode].postCharIndex;
      options.updateOptions.arcNameMode = i == 1
          ? ArcNameMode.exact
          : i == 2
              ? ArcNameMode.add
              : ArcNameMode.smart;
    }

    if (thereIsArchiveName) {
      if (curCommandIndex >= numNonSwitchStrings) {
        throw MessagePathException('Cannot find archive name');
      }
      options.archiveName = nonSwitchStrings[curCommandIndex++];
      if (options.archiveName.isEmpty) {
        throw MessagePathException('Archive name cannot by empty');
      }
    }

    nop.include = true;
    _addToCensorFromNonSwitchesStrings(
        isRename ? options.updateOptions.renamePairs : null,
        curCommandIndex,
        options.censor,
        nonSwitchStrings,
        parser.stopSwitchIndex,
        nop,
        thereAreSwitchIncludes,
        codePage);
    // not in 7-Zip: "zx a -mcompact x.zx" (no names) only compacts
    options.updateOptions.noFileNames = !isRename &&
        nonSwitchStrings.length == curCommandIndex &&
        !thereAreSwitchIncludes;

    options.passwordEnabled = parser[_K.password].thereIs;
    if (options.passwordEnabled) {
      options.password = parser[_K.password].postStrings[0];
    }

    options.showDialog = parser[_K.showDialog].thereIs;
    if (parser[_K.archiveType].thereIs) {
      options.arcType = parser[_K.archiveType].postStrings[0];
    }
    options.excludedArcTypes = List.of(parser[_K.excludedArcType].postStrings);

    _setMethodOptions(parser, options.properties);

    if (parser[_K.ntSecurity].thereIs) options.ntSecurity.setTrueTrue();
    _setBoolPair(parser, _K.altStreams, options.altStreams);
    _setBoolPair(parser, _K.hardLinks, options.hardLinks);
    _setBoolPair(parser, _K.symLinks, options.symLinks);
    _setBoolPair(parser, _K.storeOwnerId, options.storeOwnerId);
    _setBoolPair(parser, _K.storeOwnerName, options.storeOwnerName);

    if (isExtractOrList) {
      final eo = options.extractOptions;
      eo.nestDepth = options.nestDepth;
      eo.excludeDirItems = options.censor.excludeDirItems;
      eo.excludeFileItems = options.censor.excludeFileItems;
      {
        final nt = eo.ntOptions;
        nt.ntSecurity = options.ntSecurity.copy();
        nt.altStreams = options.altStreams.copy();
        if (!options.altStreams.def) nt.altStreams.val = true;
        nt.hardLinks = options.hardLinks.copy();
        if (!options.hardLinks.def) nt.hardLinks.val = true;
        nt.symLinks = options.symLinks.copy();
        if (!options.symLinks.def) nt.symLinks.val = true;
        if (parser[_K.symLinksAllowDangerous].thereIs) {
          final s = parser[_K.symLinksAllowDangerous].postStrings[0];
          var v = 9;
          if (s.isNotEmpty) {
            final vv = _stringToUInt32(s);
            if (vv == null) {
              throw MessagePathException('Unsupported switch postfix -snld', s);
            }
            v = vv;
          }
          nt.symLinksDangerousLevel = v;
        }
        nt.replaceColonForAltStream = parser[_K.replaceColonForAltStream].thereIs;
        nt.writeToAltStreamIfColon = parser[_K.writeToAltStreamIfColon].thereIs;
        nt.extractOwner = options.storeOwnerId.val;
        if (parser[_K.preserveATime].thereIs) nt.preserveATime = true;
        if (parser[_K.shareForWrite].thereIs) nt.openShareForWrite = true;
      }

      if (parser[_K.zoneFile].thereIs) {
        final s = parser[_K.zoneFile].postStrings[0];
        if (s.isNotEmpty && s != '0' && s != '1' && s != '2') {
          throw MessagePathException('Unsupported -snz:', s);
        }
        eo.zoneMode = s.isEmpty ? 1 : int.parse(s);
      }

      options.censor.addPathsToCensor(CensorPathMode.absPath);
      options.censor.extendExclude();
      if (!options.censor.allAreRelative()) {
        throw MessagePathException(
            'Cannot use absolute pathnames for this command');
      }

      final arcCensor = options.arcCensor;
      final nopArc = _NameOption()
        ..wildcardMatching = nop.wildcardMatching
        ..markMode = nop.markMode;
      if (parser[_K.arInclude].thereIs) {
        nopArc.include = true;
        _addSwitchWildcardsToCensor(
            arcCensor, parser[_K.arInclude].postStrings, nopArc, codePage);
      }
      if (parser[_K.arExclude].thereIs) {
        nopArc.include = false;
        _addSwitchWildcardsToCensor(
            arcCensor, parser[_K.arExclude].postStrings, nopArc, codePage);
      }
      if (thereIsArchiveName) {
        nopArc.include = true;
        _addNameToCensor(arcCensor, nopArc, options.archiveName);
      }
      arcCensor.addPathsToCensor(CensorPathMode.relatPath);
      arcCensor.extendExclude();

      if (options.stdInMode) {
        options.arcNameForStdInMode = parser[_K.stdIn].postStrings.first;
      }

      if (isExtractGroupCommand) {
        if (options.stdOutMode) {
          if (options.numberForPercents == kOutStreamStdout ||
              ((options.isStdOutTerminal && options.isStdErrTerminal) &&
                  options.numberForPercents != kOutStreamDisabled)) {
            throw MessagePathException(_kSameTerminalError);
          }
        }
        if (parser[_K.outputDir].thereIs) {
          // NormalizeDirSeparators (_WIN32), NormalizeDirPathPrefix
          eo.outputDir = normalizeDirPathPrefix(
              normalizeDirSeparators(parser[_K.outputDir].postStrings[0]));
        }
        if (parser[_K.outDirMode].thereIs) {
          final index = parser[_K.outDirMode].postCharIndex;
          eo.outDirMode = index == 0
              ? ExtractOutDirMode.direct
              : index == 1
                  ? ExtractOutDirMode.addArcName
                  : ExtractOutDirMode.replaceAsterisk;
        }
        eo.overwriteMode = OverwriteMode.ask;
        if (parser[_K.overwrite].thereIs) {
          eo.overwriteMode = _kOverwriteModes[parser[_K.overwrite].postCharIndex];
          eo.overwriteModeForce = true;
        } else if (options.yesToAll) {
          eo.overwriteMode = OverwriteMode.overwrite;
          eo.overwriteModeForce = true;
        }
      }

      eo.pathMode = options.command.getPathMode();
      if (censorPathMode == CensorPathMode.absPath) {
        eo.pathMode = PathMode.absPaths;
        eo.pathModeForce = true;
      } else if (censorPathMode == CensorPathMode.fullPath) {
        eo.pathMode = PathMode.fullPaths;
        eo.pathModeForce = true;
      }
    } else if (options.command.isFromUpdateGroup()) {
      if (parser[_K.arInclude].thereIs) {
        throw MessagePathException('-ai switch is not supported for this command');
      }
      final updateOptions = options.updateOptions;
      _setAddCommandOptions(options.command.commandType, parser, updateOptions);
      updateOptions.methodMode.properties = List.of(options.properties);
      if (parser[_K.preserveATime].thereIs) updateOptions.preserveATime = true;
      if (parser[_K.shareForWrite].thereIs) {
        updateOptions.openShareForWrite = true;
      }
      if (parser[_K.stopAfterOpenError].thereIs) {
        updateOptions.stopAfterOpenError = true;
      }
      updateOptions.pathMode = censorPathMode;
      updateOptions.altStreams = options.altStreams.copy();
      updateOptions.ntSecurity = options.ntSecurity.copy();
      updateOptions.hardLinks = options.hardLinks.copy();
      updateOptions.symLinks = options.symLinks.copy();
      updateOptions.storeOwnerId = options.storeOwnerId.copy();
      updateOptions.storeOwnerName = options.storeOwnerName.copy();

      updateOptions.eMailMode = parser[_K.email].thereIs;
      if (updateOptions.eMailMode) {
        updateOptions.eMailAddress = parser[_K.email].postStrings.first;
        if (updateOptions.eMailAddress.startsWith('.')) {
          updateOptions.eMailRemoveAfter = true;
          updateOptions.eMailAddress = updateOptions.eMailAddress.substring(1);
        }
      }

      updateOptions.stdOutMode = options.stdOutMode;
      updateOptions.stdInMode = options.stdInMode;
      updateOptions.deleteAfterCompressing =
          parser[_K.deleteAfterCompressing].thereIs;
      updateOptions.setArcMTime = parser[_K.setArcMTime].thereIs;

      if (updateOptions.stdOutMode && updateOptions.eMailMode) {
        throw MessagePathException(
            'stdout mode and email mode cannot be combined');
      }
      if (updateOptions.stdOutMode) {
        if (options.isStdOutTerminal) {
          throw MessagePathException(_kTerminalOutError);
        }
        if (options.numberForPercents == kOutStreamStdout ||
            options.numberForOut == kOutStreamStdout ||
            options.numberForErrors == kOutStreamStdout) {
          throw MessagePathException(_kSameTerminalError);
        }
      }
      if (updateOptions.stdInMode) {
        updateOptions.stdInFileName = parser[_K.stdIn].postStrings.first;
      }
      if (options.command.commandType == CommandType.rename) {
        if (updateOptions.commands.length != 1) {
          throw MessagePathException(
              'Only one archive can be created with rename command');
        }
      }
    } else if (options.command.commandType == CommandType.benchmark) {
      options.numIterations = 1;
      options.numIterationsDefined = false;
      if (curCommandIndex < numNonSwitchStrings) {
        final v = _stringToUInt32(nonSwitchStrings[curCommandIndex]);
        if (v == null) {
          throw MessagePathException('Incorrect number of benchmark iterations',
              nonSwitchStrings[curCommandIndex]);
        }
        options.numIterations = v;
        curCommandIndex++;
        options.numIterationsDefined = true;
      }
    } else if (options.command.commandType == CommandType.hash) {
      options.censor.addPathsToCensor(censorPathMode);
      options.censor.extendExclude();
      final hashOptions = options.hashOptions;
      hashOptions.pathMode = censorPathMode;
      hashOptions.methods = options.hashMethods;
      if (parser[_K.preserveATime].thereIs) hashOptions.preserveATime = true;
      if (parser[_K.shareForWrite].thereIs) hashOptions.openShareForWrite = true;
      hashOptions.stdInMode = options.stdInMode;
      hashOptions.altStreamsMode = options.altStreams.val;
      hashOptions.symLinks = options.symLinks.copy();
    } else if (options.command.commandType == CommandType.info) {
    } else {
      throw const ExitCodeException(20150919);
    }
  }
}
