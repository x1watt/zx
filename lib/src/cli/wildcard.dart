// File name masks and the censor tree of the include / exclude rules:
// Common/Wildcard.cpp of the LZMA SDK. POSIX: '/' is the only path
// separator. Windows (_WIN32): '\' and '/' are both separators, drive and
// "\\?\" prefixes are kept in the censor prefix, and names are case
// insensitive unless -ssc is given.

import 'common.dart';
import 'platform.dart';

export 'platform.dart' show isPathSepar;

/// The default of g_CaseSensitive: false on Windows and macOS, true
/// elsewhere (Wildcard.cpp; __APPLE__ without TARGET_OS_IPHONE).
bool defaultCaseSensitive() => !(kIsWin || kIsMac);

/// g_CaseSensitive (-ssc / -ssc- change it).
bool gCaseSensitive = defaultCaseSensitive();

int _upper(int c) {
  if (c < 0x80) {
    return (c >= 0x61 && c <= 0x7A) ? c - 0x20 : c;
  }
  final u = String.fromCharCode(c).toUpperCase();
  return u.length == 1 ? u.codeUnitAt(0) : c;
}

/// MyCharUpper.
int myCharUpper(int c) => _upper(c);

// MyStringCompare_Path / MyStringCompareNoCase_Path: 0 < separator < 1.
int _compareFileNames(String s1, String s2, bool caseSensitive) {
  final n1 = s1.length, n2 = s2.length;
  for (var i = 0;; i++) {
    final c1 = i < n1 ? s1.codeUnitAt(i) : 0;
    final c2 = i < n2 ? s2.codeUnitAt(i) : 0;
    if (c1 != c2) {
      if (c1 == 0) return -1;
      if (c2 == 0) return 1;
      var a = isPathSepar(c1) ? 0 : c1;
      var b = isPathSepar(c2) ? 0 : c2;
      if (!caseSensitive) {
        a = _upper(a);
        b = _upper(b);
      }
      if (a < b) return -1;
      if (a > b) return 1;
      continue;
    }
    if (c1 == 0) return 0;
  }
}

/// CompareFileNames.
int compareFileNames(String s1, String s2) =>
    _compareFileNames(s1, s2, gCaseSensitive);

/// IsPath1PrefixedByPath2.
bool isPath1PrefixedByPath2(String s1, String s2) {
  if (s2.length > s1.length) return false;
  if (gCaseSensitive) return s1.startsWith(s2);
  for (var i = 0; i < s2.length; i++) {
    if (_upper(s1.codeUnitAt(i)) != _upper(s2.codeUnitAt(i))) return false;
  }
  return true;
}

// EnhancedMaskTest
bool _enhancedMaskTest(String mask, int mi, String name, int ni) {
  for (;;) {
    final m = mi < mask.length ? mask.codeUnitAt(mi) : 0;
    final c = ni < name.length ? name.codeUnitAt(ni) : 0;
    if (m == 0) return c == 0;
    if (m == 0x2A) {
      // '*'
      if (_enhancedMaskTest(mask, mi + 1, name, ni)) return true;
      if (c == 0) return false;
    } else {
      if (m == 0x3F) {
        // '?'
        if (c == 0) return false;
      } else if (m != c) {
        if (gCaseSensitive || _upper(m) != _upper(c)) return false;
      }
      mi++;
    }
    ni++;
  }
}

/// SplitPathToParts.
List<String> splitPathToParts(String path) {
  final parts = <String>[];
  if (path.isEmpty) return parts;
  var prev = 0;
  for (var i = 0; i < path.length; i++) {
    if (isPathSepar(path.codeUnitAt(i))) {
      parts.add(path.substring(prev, i));
      prev = i + 1;
    }
  }
  parts.add(path.substring(prev));
  return parts;
}

/// SplitPathToParts_2: (dirPrefix, name).
(String, String) splitPathToParts2(String path) {
  var p = path.length;
  for (; p != 0; p--) {
    if (isPathSepar(path.codeUnitAt(p - 1))) break;
  }
  return (path.substring(0, p), path.substring(p));
}

/// SplitPathToParts_Smart: ignores a separator at the end of [path].
(String, String) splitPathToPartsSmart(String path) {
  var p = path.length;
  if (p != 0) {
    if (isPathSepar(path.codeUnitAt(p - 1))) p--;
    for (; p != 0; p--) {
      if (isPathSepar(path.codeUnitAt(p - 1))) break;
    }
  }
  return (path.substring(0, p), path.substring(p));
}

/// ExtractFileNameFromPath.
String extractFileNameFromPath(String path) =>
    path.substring(reverseFindPathSepar(path) + 1);

/// DoesWildcardMatchName.
bool doesWildcardMatchName(String mask, String name) =>
    _enhancedMaskTest(mask, 0, name, 0);

/// DoesNameContainWildcard.
bool doesNameContainWildcard(String path) =>
    path.contains('*') || path.contains('?');

// ---------------------------------------------------------------------------
// NWildcard

const int kMarkFileOrDir = 0;
const int kMarkStrictFile = 1;
const int kMarkStrictFileIfWildcard = 2;

/// CItem.
class WildcardItem {
  List<String> pathParts = [];
  bool recursive = false;
  bool forFile = true;
  bool forDir = true;
  bool wildcardMatching = true;

  WildcardItem copy() => WildcardItem()
    ..pathParts = List.of(pathParts)
    ..recursive = recursive
    ..forFile = forFile
    ..forDir = forDir
    ..wildcardMatching = wildcardMatching;

  // CItem::IsDriveItem (Windows)
  bool isDriveItem() =>
      kIsWin &&
      pathParts.length == 1 &&
      !forFile &&
      forDir &&
      isDriveColonName(pathParts[0]);

  // CItem::AreAllAllowed
  bool areAllAllowed() =>
      forFile &&
      forDir &&
      wildcardMatching &&
      pathParts.length == 1 &&
      pathParts.first == '*';

  // CItem::CheckPath
  bool checkPath(List<String> pathParts2, bool isFile) {
    if (!isFile && !forDir) return false;
    final delta = pathParts2.length - pathParts.length;
    if (delta < 0) return false;
    var start = 0;
    var finish = 0;
    if (isFile) {
      if (!forDir) {
        if (recursive) {
          start = delta;
        } else if (delta != 0) {
          return false;
        }
      }
      if (!forFile && delta == 0) return false;
    }
    if (recursive) {
      finish = delta;
      if (isFile && !forFile) finish = delta - 1;
    }
    for (var d = start; d <= finish; d++) {
      var i = 0;
      for (; i < pathParts.length; i++) {
        if (wildcardMatching) {
          if (!doesWildcardMatchName(pathParts[i], pathParts2[i + d])) break;
        } else {
          if (compareFileNames(pathParts[i], pathParts2[i + d]) != 0) break;
        }
      }
      if (i == pathParts.length) return true;
    }
    return false;
  }
}

/// CCensorPathProps.
class CensorPathProps {
  bool recursive = false;
  bool wildcardMatching = true;
  int markMode = kMarkFileOrDir;
  CensorPathProps copy() => CensorPathProps()
    ..recursive = recursive
    ..wildcardMatching = wildcardMatching
    ..markMode = markMode;
}

/// CCensorNode.
class CensorNode {
  CensorNode? parent;
  String name;
  final List<CensorNode> subNodes = [];
  final List<WildcardItem> includeItems = [];
  final List<WildcardItem> excludeItems = [];

  CensorNode([this.name = '', this.parent]);

  // Find_SubNode_Or_Add_New
  CensorNode findSubNodeOrAddNew(String name) {
    final i = findSubNode(name);
    if (i >= 0) return subNodes[i];
    final node = CensorNode(name, this);
    subNodes.add(node);
    return node;
  }

  // CCensorNode::AreAllAllowed
  bool areAllAllowed() {
    if (name.isNotEmpty ||
        subNodes.isNotEmpty ||
        excludeItems.isNotEmpty ||
        includeItems.length != 1) {
      return false;
    }
    return includeItems.first.areAllAllowed();
  }

  // FindSubNode
  int findSubNode(String name) {
    for (var i = 0; i < subNodes.length; i++) {
      if (compareFileNames(subNodes[i].name, name) == 0) return i;
    }
    return -1;
  }

  // AddItemSimple
  void _addItemSimple(bool include, WildcardItem item) {
    (include ? includeItems : excludeItems).add(item);
  }

  // CCensorNode::AddItem
  void addItem(bool include, WildcardItem item, [int ignoreWildcardIndex = -1]) {
    if (item.pathParts.length <= 1) {
      if (item.pathParts.isNotEmpty && item.wildcardMatching) {
        if (!doesNameContainWildcard(item.pathParts.first)) {
          item.wildcardMatching = false;
        }
      }
      _addItemSimple(include, item);
      return;
    }
    final front = item.pathParts.first;
    if (item.wildcardMatching &&
        ignoreWildcardIndex != 0 &&
        doesNameContainWildcard(front)) {
      _addItemSimple(include, item);
      return;
    }
    final subNode = findSubNodeOrAddNew(front);
    item.pathParts.removeAt(0);
    subNode.addItem(include, item, ignoreWildcardIndex - 1);
  }

  // Add_Wildcard
  void addWildcard() {
    addItem(
        true,
        WildcardItem()
          ..pathParts = ['*']
          ..recursive = false
          ..forFile = true
          ..forDir = true
          ..wildcardMatching = true);
  }

  // NeedCheckSubDirs
  bool needCheckSubDirs() {
    for (final item in includeItems) {
      if (item.recursive || item.pathParts.length > 1) return true;
    }
    return false;
  }

  // AreThereIncludeItems
  bool areThereIncludeItems() {
    if (includeItems.isNotEmpty) return true;
    for (final n in subNodes) {
      if (n.areThereIncludeItems()) return true;
    }
    return false;
  }

  // CheckPathCurrent
  bool _checkPathCurrent(bool include, List<String> pathParts, bool isFile) {
    final items = include ? includeItems : excludeItems;
    for (final item in items) {
      if (item.checkPath(pathParts, isFile)) return true;
    }
    return false;
  }

  /// CheckPathVect: returns (found, include).
  (bool, bool) checkPathVect(List<String> pathParts, bool isFile) {
    if (_checkPathCurrent(false, pathParts, isFile)) return (true, false);
    if (pathParts.length > 1) {
      final index = findSubNode(pathParts.first);
      if (index >= 0) {
        final r = subNodes[index].checkPathVect(pathParts.sublist(1), isFile);
        if (r.$1) return r;
      }
    }
    final finded = _checkPathCurrent(true, pathParts, isFile);
    return (finded, finded);
  }

  // CheckPathToRoot_Change
  bool _checkPathToRootChange(
      bool include, List<String> pathParts, bool isFile) {
    if (_checkPathCurrent(include, pathParts, isFile)) return true;
    final p = parent;
    if (p == null) return false;
    pathParts.insert(0, name);
    return p._checkPathToRootChange(include, pathParts, isFile);
  }

  // CheckPathToRoot
  bool checkPathToRoot(bool include, List<String> pathParts, bool isFile) {
    if (_checkPathCurrent(include, pathParts, isFile)) return true;
    final p = parent;
    if (p == null) return false;
    return p._checkPathToRootChange(include, [name, ...pathParts], isFile);
  }

  // ExtendExclude
  void extendExclude(CensorNode fromNodes) {
    excludeItems.addAll(fromNodes.excludeItems.map((e) => e.copy()));
    for (final node in fromNodes.subNodes) {
      findSubNodeOrAddNew(node.name).extendExclude(node);
    }
  }
}

/// CPair.
class CensorPair {
  final String prefix;
  final CensorNode head = CensorNode();
  CensorPair(this.prefix);
}

/// ECensorPathMode.
enum CensorPathMode {
  /// absolute prefix as Prefix, remain path in Tree
  relatPath,

  /// drive prefix as Prefix, remain path in Tree
  fullPath,

  /// full path in Tree
  absPath,
}

/// CCensorPath.
class CensorPath {
  final String path;
  final bool include;
  final CensorPathProps props;
  CensorPath(this.path, this.include, this.props);
}

/// IsDriveColonName: "c:".
bool isDriveColonName(String s) => s.length == 2 && isDrivePath2(s);

// GetNumPrefixParts
int _getNumPrefixParts(List<String> pathParts) {
  if (pathParts.isEmpty) return 0;
  if (!kIsWin) return pathParts[0].isEmpty ? 1 : 0;
  if (isDriveColonName(pathParts[0])) return 1;
  if (pathParts[0].isNotEmpty) return 0;
  if (pathParts.length == 1) return 1;
  if (pathParts[1].isNotEmpty) return 1;
  if (pathParts.length == 2) return 2;
  if (pathParts[2] == '.') return 3;
  var networkParts = 2;
  if (pathParts[2] == '?') {
    if (pathParts.length == 3) return 3;
    if (isDriveColonName(pathParts[3])) return 4;
    if (pathParts[3].toUpperCase() != 'UNC') return 3;
    networkParts = 4;
  }
  networkParts += 1; // server
  if (pathParts.length <= networkParts) return pathParts.length;
  return networkParts;
}

/// CCensor.
class Censor {
  final List<CensorPair> pairs = [];
  bool excludeDirItems = false;
  bool excludeFileItems = false;
  final List<CensorPath> censorPaths = [];

  // FindPairForPrefix
  int _findPairForPrefix(String prefix) {
    for (var i = 0; i < pairs.length; i++) {
      if (compareFileNames(pairs[i].prefix, prefix) == 0) return i;
    }
    return -1;
  }

  // AllAreRelative
  bool allAreRelative() => pairs.length == 1 && pairs.first.prefix.isEmpty;

  // CCensor::AddItem
  void addItem(
      CensorPathMode pathMode, bool include, String path, CensorPathProps props) {
    if (path.isEmpty) throw const StringException('Empty file path');

    final pathParts = splitPathToParts(path);
    final props2 = props.copy();

    var forFile = true;
    var forDir = true;
    final back = pathParts.last;
    if (back.isEmpty) {
      forFile = false;
      pathParts.removeLast();
    } else {
      if (props.markMode == kMarkStrictFile ||
          (props.markMode == kMarkStrictFileIfWildcard &&
              doesNameContainWildcard(back))) {
        forDir = false;
      }
    }

    final prefix = StringBuffer();
    var ignoreWildcardIndex = -1;

    if (pathParts.length >= 3 &&
        pathParts[0].isEmpty &&
        pathParts[1].isEmpty &&
        pathParts[2] == '?') {
      ignoreWildcardIndex = 2;
    }

    if (pathMode != CensorPathMode.absPath) {
      ignoreWildcardIndex = -1;
      final numPrefixParts = _getNumPrefixParts(pathParts);
      var numSkipParts = numPrefixParts;
      if (pathMode != CensorPathMode.fullPath) {
        if (numPrefixParts != 0 && pathParts.length > numPrefixParts) {
          numSkipParts = pathParts.length - 1;
        }
      }
      {
        var dotsIndex = -1;
        for (var i = numPrefixParts; i < pathParts.length; i++) {
          final part = pathParts[i];
          if (part == '..' || part == '.') dotsIndex = i;
        }
        if (dotsIndex >= 0) {
          if (dotsIndex == pathParts.length - 1) {
            numSkipParts = pathParts.length;
          } else {
            numSkipParts = pathParts.length - 1;
          }
        }
      }
      for (var i = 0; i < numSkipParts; i++) {
        final front = pathParts.first;
        if (props.wildcardMatching) {
          if (i >= numPrefixParts && doesNameContainWildcard(front)) break;
        }
        prefix.write(front);
        prefix.write(kDirSep);
        pathParts.removeAt(0);
      }
    }

    final prefixS = prefix.toString();
    var index = _findPairForPrefix(prefixS);
    if (index < 0) {
      index = pairs.length;
      pairs.add(CensorPair(prefixS));
    }

    if (pathMode != CensorPathMode.absPath) {
      if (pathParts.isEmpty || (pathParts.length == 1 && pathParts[0].isEmpty)) {
        pathParts
          ..clear()
          ..add('*');
        forFile = true;
        forDir = true;
        props2.wildcardMatching = true;
        props2.recursive = false;
      }
    }

    final item = WildcardItem()
      ..pathParts = pathParts
      ..forDir = forDir
      ..forFile = forFile
      ..recursive = props2.recursive
      ..wildcardMatching = props2.wildcardMatching;
    pairs[index].head.addItem(include, item, ignoreWildcardIndex);
  }

  // CCensor::ExtendExclude
  void extendExclude() {
    var i = 0;
    for (; i < pairs.length; i++) {
      if (pairs[i].prefix.isEmpty) break;
    }
    if (i == pairs.length) return;
    final index = i;
    for (i = 0; i < pairs.length; i++) {
      if (index != i) pairs[i].head.extendExclude(pairs[index].head);
    }
  }

  // AddPathsToCensor
  void addPathsToCensor(CensorPathMode censorPathMode) {
    for (final cp in censorPaths) {
      addItem(censorPathMode, cp.include, cp.path, cp.props);
    }
    censorPaths.clear();
  }

  // AddPreItem
  void addPreItem(bool include, String path, CensorPathProps props) {
    censorPaths.add(CensorPath(path, include, props));
  }

  // AddPreItem_NoWildcard
  void addPreItemNoWildcard(String path) {
    addPreItem(true, path, CensorPathProps()..wildcardMatching = false);
  }

  // AddPreItem_Wildcard
  void addPreItemWildcard() => addPreItem(true, '*', CensorPathProps());
}

