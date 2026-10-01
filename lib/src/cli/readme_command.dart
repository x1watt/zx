// The `zx readme` command (zx extension, docs/readme.md): shows the README
// of an archive or of a folder in it, and checks that its links and images
// stay inside the archive.
//
//   zx readme [options] ARCHIVE [FOLDER]

import 'dart:io';
import 'dart:typed_data';

import '../format/archive_types.dart';
import '../io/streams.dart';
import '../readme/readme.dart';
import '../readme/readme_links.dart';
import 'common.dart';
import 'globals.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'std_stream.dart';

const String zxReadmeUsage = '''
Usage: zx readme [OPTIONS] ARCHIVE [FOLDER]
Shows the README of the archive (README.md, README.markdown, README.txt or
README at the top), or of FOLDER in it. Images and linked files must be
entries of the archive; links to other places (http, https, mailto) are
allowed, images from other places are not.
OPTIONS:
   -check      check the links and images instead (exit code 1 when one can
               not work)
   -all        every README of the archive (every folder)
   -p{Password}  password of an encrypted archive
''';

/// The part of a README that is read.
const int _maxBytes = 1 << 20;

/// Runs `zx readme` with [args] (after the word "readme"); returns the
/// exit code.
int runReadmeCommand(List<String> args, CliIo io) {
  void out(String s) => gStdOut.write(s);
  void err(String s) {
    gStdOut.flush();
    gStdErr.write(s);
  }

  var check = false;
  var all = false;
  String? password;
  final pos = <String>[];
  for (final a in args) {
    if (a.startsWith('-') && a.length > 1) {
      final o = a.startsWith('--') ? a.substring(2) : a.substring(1);
      if (o == 'check') {
        check = true;
      } else if (o == 'all') {
        all = true;
      } else if (o == 'help' || o == 'h') {
        out(zxReadmeUsage);
        return 0;
      } else if (a.startsWith('-p')) {
        password = a.substring(2);
      } else {
        err('zx readme: Error: unknown option: $a\n$zxReadmeUsage');
        return 1;
      }
      continue;
    }
    pos.add(a);
  }
  if (pos.isEmpty || pos.length > 2) {
    err(zxReadmeUsage);
    return 1;
  }
  final archive = pos[0];
  final folder = pos.length > 1 ? _norm(pos[1]) : '';
  final cwd = io.workingDirectory;
  var path = archive;
  if (cwd != null && !File(path).isAbsolute) path = '$cwd/$path';

  final _Arc arc;
  try {
    arc = _Arc.open(path, password);
  } on _ReadmeError catch (e) {
    err('zx readme: Error: $archive: ${e.message}\n');
    return 2;
  }
  try {
    final dirs = all ? (arc.dirs.toList()..sort()) : [folder];
    var found = 0;
    var problems = 0;
    for (final d in dirs) {
      final idx = arc.readmeIn(d);
      if (idx == null) continue;
      found++;
      final p = arc.paths[idx];
      Uint8List bytes;
      try {
        bytes = arc.read(idx);
      } on _ReadmeError catch (e) {
        err('zx readme: Error: $p: ${e.message}\n');
        problems++;
        continue;
      }
      final truncated = bytes.length >= _maxBytes;
      if (!check) {
        if (all) out('==> $p <==\n');
        gStdOut.writeBytes(bytes);
        if (bytes.isNotEmpty && bytes.last != 0x0A) out('\n');
        if (truncated) out('[... the first ${_maxBytes >> 20} MiB]\n');
        if (all) out('\n');
        continue;
      }
      final doc = parseReadme(arc.names[idx], bytes, truncated: truncated);
      final issues = checkReadme(doc, readmeDirOf(p), arc.exists);
      if (issues.isEmpty) {
        out('$p: ok\n');
      } else {
        for (final i in issues) {
          out('$p: $i\n');
        }
        problems += issues.length;
      }
    }
    if (found == 0) {
      err('zx readme: ${folder.isEmpty || all ? archive : '$archive/$folder'}'
          ': no README\n');
      return 1;
    }
    return problems > 0 ? 1 : 0;
  } finally {
    arc.close();
    gStdOut.flush();
  }
}

String _norm(String p) => p
    .replaceAll('\\', '/')
    .split('/')
    .where((s) => s.isNotEmpty && s != '.')
    .join('/');

class _ReadmeError implements Exception {
  final String message;
  const _ReadmeError(this.message);
}

class _Ui extends OpenCallbackUI {
  final String? password;
  _Ui(this.password);

  @override
  String openCryptoGetTextPassword() {
    final p = password;
    if (p == null) {
      throw const _ReadmeError('the archive is encrypted, use -p{Password}');
    }
    return p;
  }
}

/// The opened archive with its paths.
class _Arc {
  final ArchiveLink link;
  final String? password;
  final List<String> paths;
  final List<String> names;
  final List<bool> isDir;

  /// The folders (with the implied ones) and the top ('').
  final Set<String> dirs;
  final Set<String> _all;

  _Arc(this.link, this.password, this.paths, this.names, this.isDir, this.dirs,
      this._all);

  factory _Arc.open(String path, String? password) {
    final codecs = Codecs.load();
    final h = codecs.findFormatForArchiveType('Hash');
    final link = ArchiveLink();
    final op = OpenOptions()
      ..codecs = codecs
      ..types = const []
      ..excludedFormats = h < 0 ? const [] : [h]
      ..stdInMode = false
      ..filePath = path;
    int res;
    try {
      res = link.openStrict(op, _Ui(password), null);
    } on SystemException catch (e) {
      link.close();
      throw _ReadmeError(myFormatMessage(e.errorCode));
    } on _ReadmeError {
      link.close();
      rethrow;
    }
    if (res != HRes.sOk) {
      link.close();
      if (link.passwordWasAsked) throw const _ReadmeError('wrong password');
      throw _ReadmeError(res == HRes.sFalse
          ? 'can not open the file as an archive'
          : myFormatMessage(res));
    }
    final arc = link.arcs.last;
    final a = arc.archive!;
    final n = a.numberOfItems;
    final paths = <String>[];
    final names = <String>[];
    final isDir = <bool>[];
    final dirs = <String>{''};
    final all = <String>{};
    for (var i = 0; i < n; i++) {
      final p = _norm(arc.getItemPath(i));
      final d = archiveIsItemDir(a, i);
      paths.add(p);
      names.add(p.substring(p.lastIndexOf('/') + 1));
      isDir.add(d);
      all.add(p);
      if (d) dirs.add(p);
      var k = p.lastIndexOf('/');
      while (k > 0) {
        final parent = p.substring(0, k);
        if (!dirs.add(parent)) break;
        all.add(parent);
        k = parent.lastIndexOf('/');
      }
    }
    return _Arc(link, password, paths, names, isDir, dirs, all);
  }

  bool exists(String path) => _all.contains(path);

  /// The index of the README of the folder [dir], or null.
  int? readmeIn(String dir) {
    final byName = <String, int>{};
    for (var i = 0; i < paths.length; i++) {
      if (isDir[i] || readmeDirOf(paths[i]) != dir) continue;
      byName[names[i]] = i;
    }
    final n = pickReadme(byName.keys);
    return n == null ? null : byName[n];
  }

  /// The first [_maxBytes] bytes of item [index].
  Uint8List read(int index) {
    final arc = link.arcs.last;
    final a = arc.archive!;
    final out = _CapOut(_maxBytes);
    final cb = _ItemCallback(out, index, password);
    try {
      a.extract(arc.isSeq ? null : [index], false, cb);
    } on _Full {
      return out.data.toBytes();
    } on SystemException catch (e) {
      throw _ReadmeError(myFormatMessage(e.errorCode));
    }
    if (cb.result != OperationResult.ok) {
      throw _ReadmeError(cb.result == OperationResult.wrongPassword
          ? 'wrong password'
          : 'can not be read');
    }
    return out.data.toBytes();
  }

  void close() {
    link.close();
    link.release();
  }
}

class _Full implements Exception {
  const _Full();
}

/// An output that keeps at most [limit] bytes.
class _CapOut implements OutStream {
  final MemoryOutStream data = MemoryOutStream();
  final int limit;
  _CapOut(this.limit);

  @override
  void write(Uint8List buf, int off, int len) {
    final room = limit - data.length;
    if (len >= room) {
      data.write(buf, off, room);
      throw const _Full();
    }
    data.write(buf, off, len);
  }

  @override
  void flush() {}
}

class _ItemCallback extends ArchiveExtractCallback
    implements CryptoGetTextPassword {
  final OutStream out;
  final int index;
  final String? password;
  int result = -1;
  bool _cur = false;
  _ItemCallback(this.out, this.index, this.password);

  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index == this.index && askMode == AskMode.extract;
    return _cur ? out : null;
  }

  @override
  void setOperationResult(int opRes) {
    if (_cur) result = opRes;
    _cur = false;
  }

  @override
  String cryptoGetTextPassword() {
    final p = password;
    if (p == null) {
      throw const _ReadmeError('the file is encrypted, use -p{Password}');
    }
    return p;
  }
}
