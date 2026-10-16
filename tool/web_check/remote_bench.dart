// Measures queries on a remote database in a browser, through the web
// engine as an app would use it: opens the URL (a part manifest or a .zx
// file) given as `?url=...` in the page's address, runs the SQL given as
// `&sql=...` (repeatable) cold and then warm, and writes the times,
// requests and bytes into #out. `$1` in a query is the first column of
// the first row of the query before it. Run with remote_bench.sh.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:zx/src/web/engine_client.dart';
import 'package:zx/src/web/wire.dart' show sqlResultFromWire;

@JS('document.getElementById')
external JSObject? _byId(String id);

@JS('document')
external JSObject get _document;

@JS('performance.now')
external double _now();

final _lines = <String>[];
void say(String s) {
  _lines.add(s);
  _byId('out')?['textContent'] = _lines.join('\n').toJS;
}

Future<void> main() async {
  final href =
      ((globalContext['location'] as JSObject)['href'] as JSString).toDart;
  final q = Uri.parse(href).queryParametersAll;
  final url = q['url']!.single;
  final sqls = q['sql'] ?? const [];
  try {
    final engine = await ZxEngine.start('engine/zx_engine_worker.js');
    var t = _now();
    final bs = int.tryParse(q['bs']?.single ?? '');
    final u = (await engine
            .call('url', args: {'url': url, if (bs != null) 'blockSize': bs}))
        .json as Map;
    final path = u['path'] as String;
    final db = (await engine.call('db.open', args: {'path': path})).json;
    Future<Map> stats() async =>
        (await engine.call('urlStats', args: {'path': path})).json as Map;
    var s = await stats();
    say('open: ${(_now() - t).round()} ms, ${s['requests']} requests, '
        '${((s['bytes'] as int) / 1024).round()} KiB (${u['parts'] ?? 1} '
        'part(s), ${u['size']} bytes)'
        '${u['warm'] == null ? '' : ', warm set ${u['warm']}'}');
    for (final pass in ['cold', 'warm']) {
      Object? prev;
      for (final sql in sqls) {
        final text = sql.replaceAll(r'$1', '$prev');
        final r0 = s['requests'] as int, b0 = s['bytes'] as int;
        t = _now();
        final r = sqlResultFromWire(
            ((await engine.call('db.sql', args: {'db': db, 'sql': text})).json
                    as Map)
                .cast());
        final ms = (_now() - t).round();
        s = await stats();
        prev = r.rows.isEmpty ? null : r.rows.first.first;
        say('$pass ${ms.toString().padLeft(5)} ms '
            '${(s['requests'] as int) - r0} requests '
            '${(((s['bytes'] as int) - b0) / 1024).round()} KiB  $text  '
            '-> ${r.rows.take(2).toList()}');
      }
    }
    say('total: ${s['requests']} requests, '
        '${((s['bytes'] as int) / 1048576).toStringAsFixed(1)} MiB');
  } catch (e) {
    say('FAIL $e');
  }
  _document['title'] = 'done'.toJS;
}
