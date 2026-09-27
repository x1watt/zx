// Desktop integration at user level (no administrator rights): the file
// associations and the "Extract to folder" entry of the file manager.
//
// Linux: a desktop entry with the archive MIME types, the default
// applications in mimeapps.list, a Nautilus script, a nautilus-python
// extension (a top level menu item once python3-nautilus is installed) and
// a Thunar custom action. Windows: ProgIDs and verbs under
// HKCU\Software\Classes through reg.exe. macOS: done by the app bundle
// (Info.plist) and a Finder Quick Action, see app/README.md.
//
// The settings toggles, the command line flags (--install-integration,
// --remove-integration, --integration-status) and tool/install_linux.sh
// all use this file. Every file operation is asynchronous.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'formats.dart';
import 'settings.dart';

/// Runs a program; null when it could not be started.
typedef CommandRunner = Future<ProcessResult?> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult?> runCommand(String exe, List<String> args) async {
  try {
    return await Process.run(exe, args);
  } on ProcessException {
    return null;
  }
}

/// What is installed.
class IntegrationStatus {
  /// zx is the default application of the archive types.
  final bool associations;

  /// The file manager has the "Extract to folder" entry.
  final bool contextMenu;

  /// The desktop entry (or the Windows ProgID) exists.
  final bool registered;

  /// Remarks for the settings page (a missing optional part...).
  final List<String> notes;

  const IntegrationStatus({
    required this.associations,
    required this.contextMenu,
    required this.registered,
    this.notes = const [],
  });

  @override
  String toString() =>
      'associations: ${associations ? 'on' : 'off'}\n'
      'context menu: ${contextMenu ? 'on' : 'off'}\n'
      'registered: ${registered ? 'yes' : 'no'}'
      '${notes.map((n) => '\nnote: $n').join()}';
}

abstract class DesktopIntegration {
  /// False where the toggles can not work (see [unsupportedReason]).
  bool get supported;
  String get unsupportedReason;

  Future<IntegrationStatus> status();

  /// Registers the application (desktop entry, icons) without changing
  /// the defaults or the menus.
  Future<void> register();

  Future<void> setAssociations(bool on);
  Future<void> setContextMenu(bool on);

  /// Removes everything [register], [setAssociations] and
  /// [setContextMenu] installed.
  Future<void> removeAll();

  factory DesktopIntegration.forPlatform(
    AppPaths paths, {
    String? executable,
    CommandRunner runner = runCommand,
  }) {
    final exe = executable ?? Platform.resolvedExecutable;
    if (Platform.isLinux) {
      return LinuxIntegration(paths, exe, runner: runner);
    }
    if (Platform.isWindows) {
      return WindowsIntegration(exe, runner: runner);
    }
    return const UnsupportedIntegration(
      'On macOS the file types come from the app bundle (Info.plist) '
      'and "Extract to folder" is a Finder Quick Action: see the README '
      'of the app.',
    );
  }
}

class UnsupportedIntegration implements DesktopIntegration {
  @override
  final String unsupportedReason;
  const UnsupportedIntegration(this.unsupportedReason);
  @override
  bool get supported => false;
  @override
  Future<IntegrationStatus> status() async => const IntegrationStatus(
    associations: false,
    contextMenu: false,
    registered: false,
  );
  @override
  Future<void> register() async {}
  @override
  Future<void> setAssociations(bool on) async {}
  @override
  Future<void> setContextMenu(bool on) async {}
  @override
  Future<void> removeAll() async {}
}

// ---------------------------------------------------------------------------
// Linux

const _desktopId = 'zx.desktop';
const _thunarId = 'zx-extract-to-folder';
const _scriptName = 'Extract to folder (zx)';

class LinuxIntegration implements DesktopIntegration {
  final AppPaths paths;

  /// The program the entries start.
  final String executable;
  final CommandRunner runner;

  /// Where the system Thunar actions are (copied when the user has none,
  /// so that they stay).
  final List<String> systemConfigDirs;

  /// The folder of the app icons (zx.svg, zx-SIZE.png); default: the
  /// assets of the bundle next to [executable].
  final String? iconSource;

  LinuxIntegration(
    this.paths,
    this.executable, {
    this.runner = runCommand,
    List<String>? systemConfigDirs,
    this.iconSource,
  }) : systemConfigDirs = systemConfigDirs ?? _xdgConfigDirs();

  static List<String> _xdgConfigDirs() {
    final v = Platform.environment['XDG_CONFIG_DIRS'];
    final l = (v == null || v.isEmpty ? '/etc/xdg' : v)
        .split(':')
        .where((s) => s.isNotEmpty)
        .toList();
    return l;
  }

  @override
  bool get supported => true;
  @override
  String get unsupportedReason => '';

  String get applicationsDir => p.join(paths.dataHome, 'applications');
  String get desktopFile => p.join(applicationsDir, _desktopId);
  String get mimeappsFile => p.join(paths.configHome, 'mimeapps.list');
  String get nautilusScript =>
      p.join(paths.dataHome, 'nautilus', 'scripts', _scriptName);
  String get nautilusExtension =>
      p.join(paths.dataHome, 'nautilus-python', 'extensions', 'zx_extract.py');
  String get thunarActions => p.join(paths.configHome, 'Thunar', 'uca.xml');
  String get iconsDir => p.join(paths.dataHome, 'icons', 'hicolor');
  String get _previousDefaultsFile =>
      p.join(paths.appConfigDir, 'previous-defaults.json');

  String get _iconSource =>
      iconSource ??
      p.join(p.dirname(executable), 'data', 'flutter_assets', 'assets', 'icon');

  // ---- status ----

  @override
  Future<IntegrationStatus> status() async {
    final defaults = await _readDefaults(mimeappsFile);
    final assoc = kPrimaryMimeTypes.every(
      (t) => (defaults[t] ?? const []).firstOrNull == _desktopId,
    );
    final menu = await File(nautilusScript).exists();
    final notes = <String>[];
    if (menu && !await _nautilusPythonInstalled()) {
      notes.add(
        'Nautilus shows the entry under Scripts. For a top level '
        '"Extract to <name>/" item install python3-nautilus '
        '(sudo apt install python3-nautilus) and restart Nautilus '
        '(nautilus -q).',
      );
    }
    return IntegrationStatus(
      associations: assoc,
      contextMenu: menu,
      registered: await File(desktopFile).exists(),
      notes: notes,
    );
  }

  static Future<bool> _nautilusPythonInstalled() async {
    for (final d in const [
      '/usr/lib/x86_64-linux-gnu/nautilus/extensions-4',
      '/usr/lib/aarch64-linux-gnu/nautilus/extensions-4',
      '/usr/lib64/nautilus/extensions-4',
      '/usr/lib/nautilus/extensions-4',
      '/usr/lib/x86_64-linux-gnu/nautilus/extensions-3.0',
      '/usr/lib/nautilus/extensions-3.0',
    ]) {
      if (await File(p.join(d, 'libnautilus-python.so')).exists()) {
        return true;
      }
    }
    return false;
  }

  // ---- desktop entry and icons ----

  @override
  Future<void> register() async {
    await Directory(applicationsDir).create(recursive: true);
    await _writeAtomic(desktopFile, desktopEntry());
    await _installIcons();
    await _refreshDatabases();
  }

  /// The contents of zx.desktop.
  String desktopEntry() =>
      '''
[Desktop Entry]
Type=Application
Name=zx
GenericName=Archive Manager
Comment=Open, create and extract archives: 7z, zip, rar, tar, gz, bz2, xz, lzh, arj
Exec=${_desktopExec([executable])} %F
Icon=zx
Terminal=false
Categories=Utility;Archiving;Compression;
Keywords=archive;compress;extract;zip;7z;rar;tar;
MimeType=${kArchiveMimeTypes.join(';')};
StartupWMClass=io.github.maxbrito.zx
StartupNotify=true
''';

  Future<void> _installIcons() async {
    final src = _iconSource;
    Future<void> copy(String from, String size, String name) async {
      final f = File(p.join(src, from));
      if (!await f.exists()) return;
      final dir = Directory(p.join(iconsDir, size, 'apps'));
      await dir.create(recursive: true);
      await f.copy(p.join(dir.path, name));
    }

    await copy('zx.svg', 'scalable', 'zx.svg');
    for (final s in const [16, 24, 32, 48, 64, 128, 256, 512]) {
      await copy('zx-$s.png', '${s}x$s', 'zx.png');
    }
  }

  Future<void> _removeIcons() async {
    await _delete(p.join(iconsDir, 'scalable', 'apps', 'zx.svg'));
    for (final s in const [16, 24, 32, 48, 64, 128, 256, 512]) {
      await _delete(p.join(iconsDir, '${s}x$s', 'apps', 'zx.png'));
    }
  }

  Future<void> _refreshDatabases() async {
    if (await Directory(applicationsDir).exists()) {
      await runner('update-desktop-database', [applicationsDir]);
    }
    if (await Directory(iconsDir).exists()) {
      await runner('gtk-update-icon-cache', ['-f', '-t', '-q', iconsDir]);
    }
  }

  // ---- associations ----

  @override
  Future<void> setAssociations(bool on) async {
    if (on) {
      if (!await File(desktopFile).exists()) await register();
      await _setDefaults();
    } else {
      await _unsetDefaults();
    }
    await _refreshDatabases();
  }

  /// The mimeapps.list files that decide defaults: the common one and the
  /// desktop specific ones that exist (they win over the common one).
  Future<List<String>> _mimeappsFiles() async {
    final out = [mimeappsFile];
    final desk = Platform.environment['XDG_CURRENT_DESKTOP'] ?? '';
    for (final d in desk.split(':')) {
      if (d.isEmpty) continue;
      final f = p.join(paths.configHome, '${d.toLowerCase()}-mimeapps.list');
      if (await File(f).exists()) out.add(f);
    }
    return out;
  }

  Future<void> _setDefaults() async {
    // remember what the user had, to give it back when switched off
    final prev = <String, Map<String, String>>{};
    final prevFile = File(_previousDefaultsFile);
    if (await prevFile.exists()) {
      try {
        final j = jsonDecode(await prevFile.readAsString());
        if (j is Map) {
          j.forEach((k, v) {
            if (k is String && v is Map) {
              prev[k] = {
                for (final e in v.entries)
                  if (e.key is String && e.value is String)
                    e.key as String: e.value as String,
              };
            }
          });
        }
      } on FormatException {
        // start again
      }
    }
    final files = await _mimeappsFiles();
    for (final f in files) {
      final ini = await _Ini.read(f);
      if (f != mimeappsFile && !ini.hasSection('Default Applications')) {
        continue;
      }
      final saved = prev[f] ??= {};
      for (final t in kArchiveMimeTypes) {
        final old = ini.get('Default Applications', t);
        if (old != null && !_listOf(old).contains(_desktopId)) {
          saved.putIfAbsent(t, () => old);
        }
        ini.set('Default Applications', t, _desktopId);
        final added = _listOf(ini.get('Added Associations', t) ?? '');
        if (!added.contains(_desktopId)) {
          ini.set(
            'Added Associations',
            t,
            '${[_desktopId, ...added].join(';')};',
          );
        }
      }
      await _backupOnce(f);
      await ini.write(f);
    }
    await Directory(paths.appConfigDir).create(recursive: true);
    await _writeAtomic(
      _previousDefaultsFile,
      const JsonEncoder.withIndent('  ').convert(prev),
    );
  }

  Future<void> _unsetDefaults() async {
    Map<String, Object?> prev = const {};
    try {
      final j = jsonDecode(await File(_previousDefaultsFile).readAsString());
      if (j is Map<String, Object?>) prev = j;
    } on FileSystemException {
      // nothing saved
    } on FormatException {
      // broken: only remove
    }
    final files = {
      ...await _mimeappsFiles(),
      for (final k in prev.keys) k,
      p.join(paths.dataHome, 'applications', 'mimeapps.list'),
    };
    for (final f in files) {
      if (!await File(f).exists()) continue;
      final ini = await _Ini.read(f);
      final saved = prev[f] is Map ? prev[f] as Map : const {};
      var changed = false;
      for (final section in const [
        'Default Applications',
        'Added Associations',
      ]) {
        for (final t in kArchiveMimeTypes) {
          final v = ini.get(section, t);
          if (v == null) continue;
          final l = _listOf(v);
          if (!l.contains(_desktopId)) continue;
          l.remove(_desktopId);
          changed = true;
          final back = section == 'Default Applications' ? saved[t] : null;
          if (back is String) {
            ini.set(section, t, back);
          } else if (l.isEmpty) {
            ini.remove(section, t);
          } else {
            ini.set(
              section,
              t,
              section == 'Default Applications'
                  ? l.join(';')
                  : '${l.join(';')};',
            );
          }
        }
      }
      if (changed) await ini.write(f);
    }
    await _delete(_previousDefaultsFile);
  }

  static List<String> _listOf(String v) =>
      v.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  Future<Map<String, List<String>>> _readDefaults(String f) async {
    final ini = await _Ini.read(f);
    final out = <String, List<String>>{};
    for (final t in kArchiveMimeTypes) {
      final v = ini.get('Default Applications', t);
      if (v != null) out[t] = _listOf(v);
    }
    // a desktop specific file wins
    for (final g in await _mimeappsFiles()) {
      if (g == f) continue;
      final i2 = await _Ini.read(g);
      for (final t in kArchiveMimeTypes) {
        final v = i2.get('Default Applications', t);
        if (v != null) out[t] = _listOf(v);
      }
    }
    return out;
  }

  // ---- context menu ----

  @override
  Future<void> setContextMenu(bool on) async {
    if (on) {
      if (!await File(desktopFile).exists()) await register();
      await _writeAtomic(
        nautilusScript,
        nautilusScriptText(),
        executable: true,
      );
      await _writeAtomic(nautilusExtension, nautilusExtensionText());
      await _addThunarAction();
    } else {
      await _delete(nautilusScript);
      await _delete(nautilusExtension);
      final cache = p.join(p.dirname(nautilusExtension), '__pycache__');
      if (await Directory(cache).exists()) {
        await for (final e in Directory(cache).list()) {
          if (p.basename(e.path).startsWith('zx_extract.')) {
            await _delete(e.path);
          }
        }
      }
      await _removeThunarAction();
    }
  }

  String nautilusScriptText() =>
      '''
#!/bin/sh
# Extract to folder (zx): extracts each selected archive into a folder
# named after it. Installed by zx (Settings, Integration); switching the
# option off removes it.
set -f
if [ -n "\$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS" ]; then
  IFS='
'
  set -- \$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS
fi
exec ${_shQuote(executable)} --extract-to-folder "\$@"
''';

  String nautilusExtensionText() {
    final exts = kArchiveExtensions.map((e) => "'.$e'").join(', ');
    final mimes = kArchiveMimeTypes.map((e) => "'$e'").join(', ');
    return '''
# zx: "Extract to <name>/" in the Nautilus context menu of archives.
# Installed by zx (Settings, Integration); switching the option off
# removes it. Needs python3-nautilus.
import os
import re
import subprocess
from urllib.parse import unquote, urlparse

from gi.repository import GObject, Nautilus

ZX = ${jsonEncode(executable)}
EXTS = ($exts)
COMPOUND = ('.tar.gz', '.tar.bz2', '.tar.xz', '.tar.lzma', '.tar.bz', '.tar.z')
MIMES = {$mimes}


def _is_archive(f):
    if f.get_uri_scheme() != 'file' or f.is_directory():
        return False
    if f.get_mime_type() in MIMES:
        return True
    n = f.get_name().lower()
    return n.endswith(EXTS) or re.search(r'\\.(\\d{3}|r\\d\\d)\$', n) is not None


def folder_name(name):
    """The folder an archive extracts to (as zx names it)."""
    low = name.lower()
    m = re.search(r'\\.\\d{3}\$', low)
    if m:
        name, low = name[:m.start()], low[:m.start()]
    m = re.search(r'\\.part\\d+\\.rar\$', low) or re.search(r'\\.r\\d\\d\$', low)
    if m:
        return name[:m.start()] or 'archive'
    for e in COMPOUND:
        if low.endswith(e) and len(low) > len(e):
            return name[:-len(e)]
    dot = low.rfind('.')
    if dot > 0 and (low[dot:] in EXTS or low[dot:] in ('.gz', '.bz2', '.xz', '.lzma', '.z')):
        name = name[:dot]
    return name or 'archive'


class ZxExtractMenu(GObject.GObject, Nautilus.MenuProvider):
    def get_file_items(self, *args):
        files = args[-1]
        if not files or not all(_is_archive(f) for f in files):
            return []
        paths = [unquote(urlparse(f.get_uri()).path) for f in files]
        if len(paths) == 1:
            label = 'Extract to "%s/"' % folder_name(os.path.basename(paths[0]))
        else:
            label = 'Extract each to its folder'
        item = Nautilus.MenuItem(
            name='ZxExtractMenu::extract_to_folder',
            label=label,
            tip='Extract into a folder named after the archive (zx)',
            icon='zx')
        item.connect('activate', self._activate, paths)
        return [item]

    def get_background_items(self, *args):
        return []

    def _activate(self, _item, paths):
        subprocess.Popen([ZX, '--extract-to-folder'] + paths,
                         start_new_session=True,
                         cwd=os.path.dirname(paths[0]))
''';
  }

  String thunarActionXml() {
    final patterns = <String>{
      for (final e in kIntegrationExtensions) '*.$e',
      for (final e in kIntegrationExtensions) '*.${e.toUpperCase()}',
    }.join(';');
    return '''
<action>
	<icon>zx</icon>
	<name>Extract to folder (zx)</name>
	<submenu></submenu>
	<unique-id>$_thunarId</unique-id>
	<command>${_xmlEscape('${_shQuote(executable)} --extract-to-folder %F')}</command>
	<description>Extract each archive into a folder named after it</description>
	<range>*</range>
	<patterns>${_xmlEscape(patterns)}</patterns>
	<other-files/>
</action>''';
  }

  static final _actionRe = RegExp(
    r'[ \t]*<action>(?:(?!</action>)[\s\S])*</action>[ \t]*\n?',
  );

  Future<void> _addThunarAction() async {
    final f = File(thunarActions);
    String text;
    if (await f.exists()) {
      text = await f.readAsString();
      await _backupOnce(thunarActions);
    } else {
      // Thunar reads the user's file instead of the system one: start from
      // the system actions so they stay
      text = '<?xml version="1.0" encoding="UTF-8"?>\n<actions>\n</actions>\n';
      for (final d in systemConfigDirs) {
        final s = File(p.join(d, 'Thunar', 'uca.xml'));
        if (await s.exists()) {
          text = await s.readAsString();
          break;
        }
      }
    }
    text = _withoutZxAction(text);
    final end = text.lastIndexOf('</actions>');
    if (end < 0) {
      throw const FileSystemException(
        'Thunar uca.xml has no </actions>: not changed',
      );
    }
    text =
        '${text.substring(0, end)}${thunarActionXml()}\n${text.substring(end)}';
    await f.parent.create(recursive: true);
    await _writeAtomic(thunarActions, text);
  }

  Future<void> _removeThunarAction() async {
    final f = File(thunarActions);
    if (!await f.exists()) return;
    final text = await f.readAsString();
    final t2 = _withoutZxAction(text);
    if (t2 != text) await _writeAtomic(thunarActions, t2);
  }

  static String _withoutZxAction(String text) => text.replaceAllMapped(
    _actionRe,
    (m) => m.group(0)!.contains('<unique-id>$_thunarId</unique-id>')
        ? ''
        : m.group(0)!,
  );

  // ---- everything ----

  @override
  Future<void> removeAll() async {
    await setContextMenu(false);
    await setAssociations(false);
    await _delete(desktopFile);
    await _removeIcons();
    await _refreshDatabases();
  }

  // ---- helpers ----

  /// A copy of a user file made before zx changes it the first time.
  Future<void> _backupOnce(String path) async {
    final f = File(path);
    final b = File('$path.zx-backup');
    if (await f.exists() && !await b.exists()) await f.copy(b.path);
  }

  static Future<void> _writeAtomic(
    String path,
    String text, {
    bool executable = false,
  }) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.zx-tmp');
    await tmp.writeAsString(text, flush: true);
    if (executable) {
      await Process.run('chmod', ['755', tmp.path]);
    }
    await tmp.rename(path);
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // not there
    }
  }
}

String _shQuote(String s) => RegExp(r'^[A-Za-z0-9_./+-]+$').hasMatch(s)
    ? s
    : "'${s.replaceAll("'", "'\\''")}'";

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The Exec value of a desktop entry (the quoting rules of the Desktop
/// Entry Specification, then the escaping of string values).
String _desktopExec(List<String> args) => args
    .map((a) {
      if (RegExp(r'^[A-Za-z0-9_./+-]+$').hasMatch(a)) return a;
      final q = a.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}');
      return '"$q"'.replaceAll(r'\', r'\\');
    })
    .join(' ');

/// A small reader and writer of the key files of mimeapps.list that keeps
/// every line it does not change (comments, order, other sections).
class _Ini {
  final List<String> lines;
  _Ini(this.lines);

  static Future<_Ini> read(String path) async {
    try {
      return _Ini(
        const LineSplitter().convert(await File(path).readAsString()),
      );
    } on FileSystemException {
      return _Ini([]);
    }
  }

  Future<void> write(String path) => LinuxIntegration._writeAtomic(
    path,
    lines.isEmpty ? '' : '${lines.join('\n')}\n',
  );

  bool hasSection(String s) => lines.any((l) => l.trim() == '[$s]');

  /// [start, end) of the lines of section [s], or null.
  (int, int)? _range(String s) {
    final i = lines.indexWhere((l) => l.trim() == '[$s]');
    if (i < 0) return null;
    var j = i + 1;
    while (j < lines.length && !lines[j].trimLeft().startsWith('[')) {
      j++;
    }
    return (i + 1, j);
  }

  int _find(String s, String key) {
    final r = _range(s);
    if (r == null) return -1;
    for (var k = r.$1; k < r.$2; k++) {
      final l = lines[k];
      final eq = l.indexOf('=');
      if (eq > 0 && l.substring(0, eq).trim() == key) return k;
    }
    return -1;
  }

  String? get(String s, String key) {
    final k = _find(s, key);
    if (k < 0) return null;
    return lines[k].substring(lines[k].indexOf('=') + 1).trim();
  }

  void set(String s, String key, String value) {
    final k = _find(s, key);
    if (k >= 0) {
      lines[k] = '$key=$value';
      return;
    }
    var r = _range(s);
    if (r == null) {
      if (lines.isNotEmpty && lines.last.trim().isNotEmpty) lines.add('');
      lines.add('[$s]');
      r = (lines.length, lines.length);
    }
    // after the last non empty line of the section
    var at = r.$2;
    while (at > r.$1 && lines[at - 1].trim().isEmpty) {
      at--;
    }
    lines.insert(at, '$key=$value');
  }

  void remove(String s, String key) {
    final k = _find(s, key);
    if (k >= 0) lines.removeAt(k);
  }
}

// ---------------------------------------------------------------------------
// Windows (HKCU only, no administrator rights)

const _progId = 'zx.archive';

class WindowsIntegration implements DesktopIntegration {
  final String executable;
  final CommandRunner runner;
  WindowsIntegration(this.executable, {this.runner = runCommand});

  @override
  bool get supported => true;
  @override
  String get unsupportedReason => '';

  static const _classes = r'HKCU\Software\Classes';

  Future<bool> _reg(List<String> args) async {
    final r = await runner('reg', args);
    return r != null && r.exitCode == 0;
  }

  Future<bool> _add(
    String key, {
    String? name,
    String? value,
    String type = 'REG_SZ',
  }) => _reg([
    'add',
    key,
    if (name == null) '/ve' else ...['/v', name],
    '/t',
    type,
    if (value != null) ...['/d', value],
    '/f',
  ]);

  Future<bool> _del(String key, {String? name}) => _reg([
    'delete',
    key,
    if (name != null) ...['/v', name],
    '/f',
  ]);

  Future<bool> _exists(String key, {String? name}) => _reg([
    'query',
    key,
    if (name != null) ...['/v', name],
  ]);

  Future<String?> _value(String key) async {
    final r = await runner('reg', ['query', key, '/ve']);
    if (r == null || r.exitCode != 0) return null;
    final m = RegExp(r'REG_SZ\s+(.*)').firstMatch('${r.stdout}');
    return m?.group(1)?.trim();
  }

  String get _exeQ => '"$executable"';

  @override
  Future<void> register() async {
    final k = '$_classes\\$_progId';
    await _add(k, value: 'Archive (zx)');
    await _add('$k\\DefaultIcon', value: '$_exeQ,0');
    await _add('$k\\shell\\open\\command', value: '$_exeQ "%1"');
    await _add(
      '$k\\shell\\zx.extract',
      name: 'MUIVerb',
      value: 'Extract to folder (zx)',
    );
    await _add(
      '$k\\shell\\zx.extract\\command',
      value: '$_exeQ --extract-to-folder "%1"',
    );
    final app = '$_classes\\Applications\\${executable.split('\\').last}';
    await _add(app, name: 'FriendlyAppName', value: 'zx');
    await _add('$app\\shell\\open\\command', value: '$_exeQ "%1"');
    for (final e in kIntegrationExtensions) {
      await _add('$app\\SupportedTypes', name: '.$e', value: '');
      await _add(
        '$_classes\\.$e\\OpenWithProgids',
        name: _progId,
        type: 'REG_NONE',
      );
    }
  }

  @override
  Future<IntegrationStatus> status() async {
    final registered = await _exists('$_classes\\$_progId');
    var assoc = registered;
    for (final e in const ['7z', 'zip', 'rar']) {
      if (await _value('$_classes\\.$e') != _progId) assoc = false;
    }
    final menu = await _exists(
      '$_classes\\SystemFileAssociations\\.zip\\shell\\zx.extract',
    );
    return IntegrationStatus(
      associations: assoc,
      contextMenu: menu,
      registered: registered,
      notes: const [
        'Windows keeps a default chosen in "Open with" (UserChoice) over '
            'the per user class: if an archive still opens elsewhere, pick '
            'zx once in "Open with, Always".',
      ],
    );
  }

  @override
  Future<void> setAssociations(bool on) async {
    if (on) {
      await register();
      for (final e in kIntegrationExtensions) {
        await _add('$_classes\\.$e', value: _progId);
      }
    } else {
      for (final e in kIntegrationExtensions) {
        if (await _value('$_classes\\.$e') == _progId) {
          await _reg(['delete', '$_classes\\.$e', '/ve', '/f']);
        }
      }
    }
  }

  @override
  Future<void> setContextMenu(bool on) async {
    for (final e in kIntegrationExtensions) {
      final k = '$_classes\\SystemFileAssociations\\.$e\\shell\\zx.extract';
      if (on) {
        await _add(k, name: 'MUIVerb', value: 'Extract to folder (zx)');
        await _add(k, name: 'Icon', value: '$_exeQ,0');
        await _add('$k\\command', value: '$_exeQ --extract-to-folder "%1"');
      } else {
        await _del(k);
      }
    }
  }

  @override
  Future<void> removeAll() async {
    await setContextMenu(false);
    await setAssociations(false);
    for (final e in kIntegrationExtensions) {
      await _del('$_classes\\.$e\\OpenWithProgids', name: _progId);
    }
    await _del('$_classes\\Applications\\${executable.split('\\').last}');
    await _del('$_classes\\$_progId');
  }
}
