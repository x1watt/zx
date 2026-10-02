// The messages between the web UI and the engine worker
// (docs/architecture.md section 20) as JSON values: the listing goes in
// columns (one list per field, a field that is null for every item is
// left out), so a listing of 100 000 items is one string the browser
// parses natively. Plain Dart, used on both sides: the engine compiles it
// with dart2wasm, the UI with dart2js and dart2wasm.
//
// Integers above 2^53 (DATETIME values of SQL results) lose their last
// bits in the UI when it runs as JavaScript; sizes and offsets do not get
// there.

import 'dart:convert';
import 'dart:typed_data';

import '../api_types.dart';
import '../db/sql/sql_result.dart';
import '../db/storage_api.dart' show ZxDbException, ZxDbError;
import '../format/zx/zx_seal_types.dart';
import '../io/streams.dart' show SevenZipException, SevenZipError;
import '../readme/markdown.dart';
import '../zx_types.dart';

// ---------------------------------------------------------------------------
// Small helpers

String? _hex(List<int>? b) {
  if (b == null) return null;
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List? _unhex(Object? s) {
  if (s is! String) return null;
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

int? _us(DateTime? t) => t?.microsecondsSinceEpoch;
DateTime? _time(Object? v) =>
    v is int ? DateTime.fromMicrosecondsSinceEpoch(v, isUtc: true) : null;

List<String> _strings(Object? v) =>
    v is List ? [for (final s in v) s as String] : const [];

// ---------------------------------------------------------------------------
// Listing

/// [l] as a JSON value (see [listingFromWire]).
Map<String, Object?> listingToWire(ZxListing l) {
  final items = l.items;
  final n = items.length;
  // a column per field, dropped when it holds no value
  Map<String, List<Object?>> cols = {};
  void col(String key, Object? Function(ZxItem) f) {
    List<Object?>? c;
    for (var i = 0; i < n; i++) {
      final v = f(items[i]);
      if (v != null) (c ??= List<Object?>.filled(n, null))[i] = v;
    }
    if (c != null) cols[key] = c;
  }

  col('i', (it) => it.index);
  col('p', (it) => it.path);
  col(
      'f',
      (it) =>
          (it.isDir ? 1 : 0) | (it.isImplied ? 2 : 0) | (it.encrypted ? 4 : 0));
  col('s', (it) => it.size);
  col('k', (it) => it.packSize);
  col('mt', (it) => _us(it.modified));
  col('ct', (it) => _us(it.created));
  col('at', (it) => _us(it.accessed));
  col('a', (it) => it.attrib);
  col('pm', (it) => it.posixMode);
  col('crc', (it) => it.crc);
  col('m', (it) => it.method);
  col('sl', (it) => it.symlinkTarget);
  col('hl', (it) => it.hardlinkTarget);
  col('cm', (it) => it.comment);
  col('nc', (it) => it.nestChain);
  col('nf', (it) => it.nestedFormat);
  col('sha', (it) => it.sha256);
  col('tl', (it) => it.tlsh);
  col('g', (it) => it.generation);
  final c = l.capabilities;
  return {
    'format': l.format,
    'outer': l.outerFormats,
    'size': l.physicalSize,
    'method': l.method,
    'solid': l.solid,
    'encHeaders': l.encryptedHeaders,
    'comment': l.comment,
    'errors': l.errors,
    'warnings': l.warnings,
    'volumes': l.volumes,
    'caps': [
      c.canAdd,
      c.canDelete,
      c.canRename,
      c.canCreateFolder,
      c.canSetComment,
      c.canEncrypt,
      c.canEncryptHeaders
    ],
    'password': l.password,
    'sequential': l.sequential,
    'versions': [
      for (final v in l.versions)
        [v.number, _us(v.time), v.added, v.deleted, v.packSize]
    ],
    'numVersions': l.numVersions,
    'n': n,
    'items': cols,
  };
}

ZxListing listingFromWire(Map<String, Object?> m) {
  final n = m['n'] as int;
  final cols = (m['items'] as Map).cast<String, Object?>();
  List<Object?> col(String key) =>
      (cols[key] as List?) ?? List<Object?>.filled(n, null);
  final idx = col('i'),
      path = col('p'),
      flags = col('f'),
      size = col('s'),
      pack = col('k'),
      mt = col('mt'),
      ct = col('ct'),
      at = col('at'),
      attr = col('a'),
      pm = col('pm'),
      crc = col('crc'),
      meth = col('m'),
      sl = col('sl'),
      hl = col('hl'),
      cm = col('cm'),
      nc = col('nc'),
      nf = col('nf'),
      sha = col('sha'),
      tl = col('tl'),
      gen = col('g');
  final items = <ZxItem>[
    for (var i = 0; i < n; i++)
      ZxItem(
        index: idx[i] as int,
        path: path[i] as String,
        isDir: ((flags[i] as int) & 1) != 0,
        isImplied: ((flags[i] as int) & 2) != 0,
        encrypted: ((flags[i] as int) & 4) != 0,
        size: size[i] as int?,
        packSize: pack[i] as int?,
        modified: _time(mt[i]),
        created: _time(ct[i]),
        accessed: _time(at[i]),
        attrib: attr[i] as int?,
        posixMode: pm[i] as int?,
        crc: crc[i] as int?,
        method: meth[i] as String?,
        symlinkTarget: sl[i] as String?,
        hardlinkTarget: hl[i] as String?,
        comment: cm[i] as String?,
        nestChain:
            nc[i] == null ? null : [for (final x in nc[i] as List) x as int],
        nestedFormat: nf[i] as String?,
        sha256: sha[i] as String?,
        tlsh: tl[i] as String?,
        generation: gen[i] as int?,
      )
  ];
  final caps = [for (final b in m['caps'] as List) b as bool];
  return ZxListing(
    format: m['format'] as String,
    outerFormats: _strings(m['outer']),
    physicalSize: m['size'] as int,
    method: m['method'] as String?,
    solid: m['solid'] as bool,
    encryptedHeaders: m['encHeaders'] as bool,
    comment: m['comment'] as String?,
    errors: _strings(m['errors']),
    warnings: _strings(m['warnings']),
    volumes: _strings(m['volumes']),
    capabilities: ZxCapabilities(
        canAdd: caps[0],
        canDelete: caps[1],
        canRename: caps[2],
        canCreateFolder: caps[3],
        canSetComment: caps[4],
        canEncrypt: caps[5],
        canEncryptHeaders: caps[6]),
    items: items,
    password: m['password'] as String?,
    sequential: m['sequential'] as bool,
    versions: [
      for (final v in m['versions'] as List)
        ZxVersion(
            v[0] as int, _time(v[1])!, v[2] as int, v[3] as int, v[4] as int)
    ],
    numVersions: m['numVersions'] as int,
  );
}

// ---------------------------------------------------------------------------
// Results

List<Object?> extractResultToWire(ZxExtractResult r) => [
      r.files,
      r.dirs,
      r.bytes,
      r.skipped,
      [
        for (final e in r.errors) [e.path, e.kind.name, e.message]
      ]
    ];

ZxExtractResult extractResultFromWire(List<Object?> w) => ZxExtractResult(
      w[0] as int,
      w[1] as int,
      w[2] as int,
      w[3] as int,
      [
        for (final e in w[4] as List)
          ZxItemError(e[0] as String,
              SevenZipError.values.byName(e[1] as String), e[2] as String?)
      ],
    );

List<Object?> progressToWire(SevenZipProgress p) =>
    [p.doneBytes, p.totalBytes, p.currentFile];

SevenZipProgress progressFromWire(List<Object?> w) =>
    SevenZipProgress(w[0] as int, w[1] as int, w[2] as String?);

Map<String, Object?> passwordRequestToWire(ZxPasswordRequest r) => {
      'archive': r.archivePath,
      'reason': r.reason.name,
      'item': r.itemPath,
      'retry': r.retry,
      'attempt': r.attempt,
    };

ZxPasswordRequest passwordRequestFromWire(Map<String, Object?> m) =>
    ZxPasswordRequest(m['archive'] as String,
        ZxPasswordReason.values.byName(m['reason'] as String),
        itemPath: m['item'] as String?,
        retry: m['retry'] as bool,
        attempt: m['attempt'] as int);

// ---------------------------------------------------------------------------
// Seals

Map<String, Object?> _policyToWire(ZxPolicy p) => {
      'admin': _hex(p.admin),
      'maintainers': [for (final k in p.maintainers) _hex(k)],
      'rule': p.rule.name,
      'seq': p.seq,
      'active': p.active,
    };

ZxPolicy _policyFromWire(Map m) => ZxPolicy(_unhex(m['admin'])!,
    maintainers: [for (final k in m['maintainers'] as List) _unhex(k)!],
    rule: ZxWriteRule.values.byName(m['rule'] as String),
    seq: m['seq'] as int,
    active: m['active'] as bool);

List<Object?> sealsToWire(List<ZxGenerationSeal> gens) => [
      for (final g in gens)
        {
          'g': g.generation,
          'end': g.footerEnd,
          'state': g.state.name,
          'role': g.role,
          'problem': g.problem,
          'covered': g.covered,
          if (g.seal case final s?)
            'seal': {
              'generation': s.generation,
              'dataStart': s.dataStart,
              'dataHash': _hex(s.dataHash),
              'indexHash': _hex(s.indexHash),
              'prevRoot': _hex(s.prevRoot),
              'prefixHash': _hex(s.prefixHash),
              'policy': _policyToWire(s.policy),
              'accept': _hex(s.accept),
              'signer': _hex(s.signer),
              'signature': _hex(s.signature),
              'root': _hex(s.root),
            },
        }
    ];

List<ZxGenerationSeal> sealsFromWire(List<Object?> w) => [
      for (final o in w)
        () {
          final m = o as Map;
          final s = m['seal'] as Map?;
          final seal = s == null
              ? null
              : ZxSeal(
                  s['generation'] as int,
                  s['dataStart'] as int,
                  _unhex(s['dataHash'])!,
                  _unhex(s['indexHash'])!,
                  _unhex(s['prevRoot']),
                  _unhex(s['prefixHash']),
                  _policyFromWire(s['policy'] as Map),
                  _unhex(s['accept']),
                  _unhex(s['signer']),
                  _unhex(s['signature']),
                  _unhex(s['root'])!);
          return ZxGenerationSeal(m['g'] as int, m['end'] as int, seal,
              ZxSealState.values.byName(m['state'] as String))
            ..role = m['role'] as String?
            ..problem = m['problem'] as String?
            ..covered = m['covered'] as bool;
        }()
    ];

// ---------------------------------------------------------------------------
// SQL

Object? _valueToWire(Object? v) => v is Uint8List ? {'b': base64Encode(v)} : v;

Object? _valueFromWire(Object? v) =>
    v is Map ? base64Decode(v['b'] as String) : v;

Map<String, Object?> sqlResultToWire(ZxSqlResult r) => {
      'columns': r.columns,
      'rows': [
        for (final row in r.rows) [for (final v in row) _valueToWire(v)]
      ],
      'changes': r.changes,
      'lastId': r.lastInsertRowid,
      'types': r.types,
    };

ZxSqlResult sqlResultFromWire(Map<String, Object?> m) => ZxSqlResult(
      _strings(m['columns']),
      [
        for (final row in m['rows'] as List)
          [for (final v in row as List) _valueFromWire(v)]
      ],
      m['changes'] as int,
      m['lastId'] as int,
      types: [for (final t in m['types'] as List) t as String?],
    );

/// SQL parameters (a list or a map of values) as a JSON value.
Object? sqlParamsToWire(Object? params) => switch (params) {
      null => null,
      List() => [for (final v in params) _valueToWire(v)],
      Map() => {
          for (final e in params.entries) '${e.key}': _valueToWire(e.value)
        },
      _ => throw ArgumentError.value(params, 'params', 'a List or a Map'),
    };

Object? sqlParamsFromWire(Object? w) => switch (w) {
      null => null,
      List() => [for (final v in w) _valueFromWire(v)],
      Map() => {
          for (final e in w.entries) e.key as String: _valueFromWire(e.value)
        },
      _ => null,
    };

// ---------------------------------------------------------------------------
// Errors

Map<String, Object?> errorToWire(Object e) => switch (e) {
      SevenZipException() => {
          'type': 'archive',
          'kind': e.kind.name,
          'message': e.message
        },
      ZxDbException() => {
          'type': 'db',
          'kind': e.kind.name,
          'message': e.message
        },
      ArgumentError() => {'type': 'argument', 'message': '${e.message}'},
      _ => {'type': 'other', 'message': '$e'},
    };

/// The exception a [errorToWire] value stands for.
Object errorFromWire(Map<String, Object?> m) {
  final msg = m['message'] as String? ?? '';
  return switch (m['type']) {
    'archive' =>
      SevenZipException(msg, SevenZipError.values.byName(m['kind'] as String)),
    'db' => ZxDbException(msg, ZxDbError.values.byName(m['kind'] as String)),
    'argument' => ArgumentError(msg),
    _ => StateError(msg),
  };
}

// ---------------------------------------------------------------------------
// READMEs: the engine parses (a README is up to 1 MiB), the UI gets the
// document. Each node is a list whose first element names its kind.

List<Object?> _inlinesToWire(List<MdInline> l) => [
      for (final i in l)
        switch (i) {
          MdText() => ['t', i.text],
          MdCode() => ['c', i.code],
          MdEmphasis() => ['em', _inlinesToWire(i.children)],
          MdStrong() => ['st', _inlinesToWire(i.children)],
          MdStrike() => ['del', _inlinesToWire(i.children)],
          MdLink() => ['a', i.url, i.title, _inlinesToWire(i.children)],
          MdImage() => ['img', i.url, i.title, i.alt, i.width, i.height],
          MdBreak() => ['br', i.hard],
        }
    ];

List<MdInline> _inlinesFromWire(Object? w) => [
      for (final o in w as List)
        () {
          final n = o as List;
          return switch (n[0]) {
            't' => MdText(n[1] as String),
            'c' => MdCode(n[1] as String),
            'em' => MdEmphasis(_inlinesFromWire(n[1])),
            'st' => MdStrong(_inlinesFromWire(n[1])),
            'del' => MdStrike(_inlinesFromWire(n[1])),
            'a' =>
              MdLink(n[1] as String, n[2] as String?, _inlinesFromWire(n[3])),
            'img' => MdImage(n[1] as String, n[2] as String?, n[3] as String,
                width: n[4] as int?, height: n[5] as int?),
            _ => MdBreak(n[1] as bool),
          };
        }()
    ];

List<Object?> _blocksToWire(List<MdBlock> l) => [
      for (final b in l)
        switch (b) {
          MdHeading() => ['h', b.level, _inlinesToWire(b.text), b.slug],
          MdParagraph() => ['p', _inlinesToWire(b.text)],
          MdCodeBlock() => ['pre', b.info, b.code],
          MdQuote() => ['q', _blocksToWire(b.blocks)],
          MdList() => [
              'ul',
              b.ordered,
              b.start,
              b.tight,
              [
                for (final it in b.items) [it.checked, _blocksToWire(it.blocks)]
              ]
            ],
          MdRule() => ['hr'],
          MdTable() => [
              'tab',
              [for (final a in b.aligns) a.index],
              [for (final c in b.header) _inlinesToWire(c)],
              [
                for (final r in b.rows) [for (final c in r) _inlinesToWire(c)]
              ]
            ],
        }
    ];

List<MdBlock> _blocksFromWire(Object? w) => [
      for (final o in w as List)
        () {
          final n = o as List;
          return switch (n[0]) {
            'h' =>
              MdHeading(n[1] as int, _inlinesFromWire(n[2]), n[3] as String),
            'p' => MdParagraph(_inlinesFromWire(n[1])),
            'pre' => MdCodeBlock(n[1] as String?, n[2] as String),
            'q' => MdQuote(_blocksFromWire(n[1])),
            'ul' => MdList(n[1] as bool, n[2] as int, n[3] as bool, [
                for (final it in n[4] as List)
                  MdListItem((it as List)[0] as bool?, _blocksFromWire(it[1]))
              ]),
            'tab' => MdTable([
                for (final a in n[1] as List) MdAlign.values[a as int]
              ], [
                for (final c in n[2] as List) _inlinesFromWire(c)
              ], [
                for (final r in n[3] as List)
                  [for (final c in r as List) _inlinesFromWire(c)]
              ]),
            _ => const MdRule(),
          };
        }()
    ];

Map<String, Object?> markdownToWire(MdDocument d) =>
    {'blocks': _blocksToWire(d.blocks), 'truncated': d.truncated};

MdDocument markdownFromWire(Map<String, Object?> m) =>
    MdDocument(_blocksFromWire(m['blocks']), truncated: m['truncated'] as bool);
