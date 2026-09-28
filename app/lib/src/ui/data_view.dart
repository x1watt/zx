// The Data view of an archive with a database: the tables, views, KV
// stores, time series and system tables in groups; a table browser with
// paging and sorting; a query box with its results and errors; export of
// the rows to CSV or JSON. Every query runs in the database's worker
// isolate (DbSession); this file only shows the rows.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../db_session.dart';
import '../services.dart';
import 'format_utils.dart';

const _pageSize = 100;

String dbErrorText(Object e) => e is ZxDbException ? e.message : '$e';

/// Asks where to save [rows] and writes them as CSV or JSON (the text is
/// made in a background isolate). Returns the path written, or null.
Future<String?> exportRows(
  FilePicker picker,
  DbRows rows, {
  required bool json,
  required String baseName,
  String? initialDirectory,
}) async {
  final path = await picker.saveFile(
    initialDirectory: initialDirectory,
    suggestedName: '$baseName.${json ? 'json' : 'csv'}',
  );
  if (path == null) return null;
  final text = await compute(json ? rowsToJson : rowsToCsv, rows);
  await File(path).writeAsString(text);
  return path;
}

/// A grid of result rows with sortable column headers.
class ResultGrid extends StatelessWidget {
  final DbRows rows;
  final String? sortColumn;
  final bool ascending;

  /// Called with a column name when its header is clicked (null: the
  /// headers do not sort).
  final ValueChanged<String>? onSort;

  /// The number of the first row shown (for the row numbers).
  final int firstRow;

  const ResultGrid({
    super.key,
    required this.rows,
    this.sortColumn,
    this.ascending = true,
    this.onSort,
    this.firstRow = 0,
  });

  List<double> _widths() {
    final w = <double>[];
    for (var c = 0; c < rows.columns.length; c++) {
      var n = rows.columns[c].length + 2;
      for (final r in rows.rows.take(50)) {
        final l = cellText(
          r[c],
          maxChars: 60,
          datetime: rows.datetimeColumns.contains(rows.columns[c]),
        ).length;
        if (l > n) n = l;
      }
      w.add((n * 8.2 + 24).clamp(70, 360).toDouble());
    }
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final widths = _widths();
    const numW = 56.0;
    final total = widths.fold<double>(numW, (a, b) => a + b);
    final mono = kMonoStyle.copyWith(fontSize: 12.5, color: cs.onSurface);
    Widget header() => Container(
      color: cs.surfaceContainerHigh,
      height: 30,
      child: Row(
        children: [
          const SizedBox(width: numW),
          for (var c = 0; c < rows.columns.length; c++)
            InkWell(
              key: Key('col:${rows.columns[c]}'),
              onTap: onSort == null ? null : () => onSort!(rows.columns[c]),
              child: Container(
                width: widths[c],
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        rows.columns[c],
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (sortColumn == rows.columns[c])
                      Icon(
                        ascending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 14,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final width = total < box.maxWidth ? box.maxWidth : total;
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header(),
                  Divider(height: 1, color: cs.outlineVariant),
                  Expanded(
                    child: rows.rows.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'No rows',
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                          )
                        : ListView.builder(
                            itemExtent: 26,
                            itemCount: rows.rows.length,
                            itemBuilder: (context, i) {
                              final r = rows.rows[i];
                              return Container(
                                color: i.isOdd
                                    ? cs.surfaceContainerLowest
                                    : null,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: numW,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: Text(
                                          '${firstRow + i + 1}',
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                    for (var c = 0; c < r.length; c++)
                                      Container(
                                        width: widths[c],
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        alignment:
                                            r[c] is num &&
                                                !rows.datetimeColumns.contains(
                                                  rows.columns[c],
                                                )
                                            ? Alignment.centerRight
                                            : Alignment.centerLeft,
                                        child: Text(
                                          cellText(
                                            r[c],
                                            datetime: rows.datetimeColumns
                                                .contains(rows.columns[c]),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: r[c] == null
                                              ? mono.copyWith(
                                                  color: cs.outline,
                                                  fontStyle: FontStyle.italic,
                                                )
                                              : mono,
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The Data view: object list on the left, a table or the query box on
/// the right.
class DataView extends StatefulWidget {
  final DbSession session;
  final FilePicker picker;

  /// The folder the export dialog starts in.
  final String? exportDirectory;

  const DataView({
    super.key,
    required this.session,
    required this.picker,
    this.exportDirectory,
  });

  @override
  State<DataView> createState() => DataViewState();
}

class DataViewState extends State<DataView> {
  List<DbObject>? _objects;
  Object? _listError;
  DbObject? _selected; // null: the query box
  int _loadedVersion = -1;

  // table browser
  DbRows? _page;
  int _offset = 0;
  int? _count;
  String? _sort;
  bool _asc = true;
  Object? _tableError;
  bool _loading = false;

  // query box
  final _query = TextEditingController(
    text: 'SELECT path, size FROM zx_files ORDER BY size DESC LIMIT 100;',
  );
  DbRows? _result;
  String? _queryError;
  String? _queryNote;
  bool _running = false;

  DbSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _s.addListener(_onSession);
    _loadObjects();
  }

  @override
  void didUpdateWidget(DataView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _selected = null;
      _page = null;
      _loadObjects();
    }
  }

  @override
  void dispose() {
    _s.removeListener(_onSession);
    _query.dispose();
    super.dispose();
  }

  void _onSession() {
    if (_s.version != _loadedVersion) {
      _loadObjects();
      if (_selected != null) {
        _count = null;
        _loadPage();
      }
    }
  }

  Future<void> _loadObjects() async {
    _loadedVersion = _s.version;
    try {
      final o = await _s.objects();
      if (!mounted) return;
      setState(() {
        _objects = o;
        _listError = null;
        if (_selected != null &&
            !o.any(
              (x) => x.name == _selected!.name && x.kind == _selected!.kind,
            )) {
          _selected = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _listError = e);
    }
  }

  /// Shows [name] in the table browser (for tests and the menu).
  void selectObject(DbObject o) {
    setState(() {
      _selected = o;
      _offset = 0;
      _count = null;
      _sort = null;
      _asc = true;
      _page = null;
    });
    _loadPage();
  }

  Future<void> _loadPage() async {
    final o = _selected;
    if (o == null) return;
    setState(() => _loading = true);
    try {
      final rows = await _s.page(
        o.name,
        offset: _offset,
        limit: _pageSize,
        sortBy: _sort,
        ascending: _asc,
      );
      final n = _count ?? await _s.count(o.name);
      if (!mounted || _selected != o) return;
      setState(() {
        _page = rows;
        _count = n;
        _tableError = null;
      });
    } catch (e) {
      if (mounted && _selected == o) setState(() => _tableError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _sortBy(String col) {
    setState(() {
      if (_sort == col) {
        _asc = !_asc;
      } else {
        _sort = col;
        _asc = true;
      }
      _offset = 0;
    });
    _loadPage();
  }

  Future<void> runQuery() async {
    final sql = _query.text.trim();
    if (sql.isEmpty || _running) return;
    setState(() {
      _running = true;
      _queryError = null;
      _queryNote = null;
    });
    final sw = Stopwatch()..start();
    try {
      final r = await _s.execute(sql);
      if (!mounted) return;
      final ms = sw.elapsedMilliseconds;
      setState(() {
        _result = DbRows.of(r);
        _queryNote = r.columns.isEmpty
            ? '${r.changes} row${r.changes == 1 ? '' : 's'} changed, $ms ms'
            : '${r.rows.length} row${r.rows.length == 1 ? '' : 's'}, $ms ms';
      });
    } catch (e) {
      if (mounted) setState(() => _queryError = dbErrorText(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _export(bool json) async {
    final o = _selected;
    DbRows? rows;
    try {
      rows = o == null
          ? _result
          : await _s.all(o.name, sortBy: _sort, ascending: _asc);
    } catch (e) {
      _snack('Export: ${dbErrorText(e)}');
      return;
    }
    if (rows == null) return;
    try {
      final path = await exportRows(
        widget.picker,
        rows,
        json: json,
        baseName: o?.name ?? 'query',
        initialDirectory: widget.exportDirectory,
      );
      if (path != null) {
        _snack('Saved ${rows.rows.length} rows to ${p.basename(path)}');
      }
    } on FileSystemException catch (e) {
      _snack('Export: ${e.message}');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          width: 520,
        ),
      );
  }

  // ---- building ----

  static const _groups = [
    (DbObjectKind.table, 'Tables', Icons.table_chart_outlined),
    (DbObjectKind.view, 'Views', Icons.preview_outlined),
    (DbObjectKind.kv, 'KV stores', Icons.key_rounded),
    (DbObjectKind.series, 'Time series', Icons.show_chart_rounded),
    (DbObjectKind.system, 'System tables', Icons.settings_suggest_outlined),
  ];

  Widget _sidebar(ColorScheme cs) {
    final objs = _objects;
    final children = <Widget>[
      ListTile(
        key: const Key('data-query'),
        dense: true,
        selected: _selected == null,
        leading: const Icon(Icons.terminal_rounded, size: 18),
        title: const Text('SQL query'),
        onTap: () => setState(() => _selected = null),
      ),
      const Divider(height: 1),
    ];
    if (_listError != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            dbErrorText(_listError!),
            style: TextStyle(color: cs.error),
          ),
        ),
      );
    } else if (objs == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    } else {
      for (final (kind, label, icon) in _groups) {
        final list = objs.where((o) => o.kind == kind).toList();
        if (list.isEmpty && kind != DbObjectKind.table) continue;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 4),
            child: Text(
              '$label (${list.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        );
        if (list.isEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 4),
              child: Text(
                'none',
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
            ),
          );
        }
        for (final o in list) {
          final sel = _selected?.name == o.name && _selected?.kind == o.kind;
          children.add(
            ListTile(
              key: Key('obj:${o.name}'),
              dense: true,
              visualDensity: VisualDensity.compact,
              selected: sel,
              leading: Icon(icon, size: 16),
              title: Text(o.name, overflow: TextOverflow.ellipsis),
              onTap: () => selectObject(o),
            ),
          );
        }
      }
    }
    return ListView(children: children);
  }

  Widget _exportButtons(bool enabled) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        key: const Key('export-csv'),
        onPressed: enabled ? () => _export(false) : null,
        icon: const Icon(Icons.download_rounded, size: 16),
        label: const Text('CSV'),
      ),
      TextButton.icon(
        key: const Key('export-json'),
        onPressed: enabled ? () => _export(true) : null,
        icon: const Icon(Icons.data_object_rounded, size: 16),
        label: const Text('JSON'),
      ),
    ],
  );

  Widget _tableBrowser(ColorScheme cs, DbObject o) {
    final page = _page;
    final n = _count;
    final last = page == null ? _offset : _offset + page.rows.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  o.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Text(
                n == null
                    ? ''
                    : n == 0
                    ? '0 rows'
                    : 'Rows ${_offset + 1}-$last of $n',
                key: const Key('page-label'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              IconButton(
                key: const Key('page-prev'),
                tooltip: 'Previous page',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: _offset > 0 && !_loading
                    ? () {
                        _offset = (_offset - _pageSize).clamp(0, 1 << 62);
                        _loadPage();
                      }
                    : null,
              ),
              IconButton(
                key: const Key('page-next'),
                tooltip: 'Next page',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: n != null && last < n && !_loading
                    ? () {
                        _offset += _pageSize;
                        _loadPage();
                      }
                    : null,
              ),
              _exportButtons(page != null),
            ],
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        Expanded(
          child: _tableError != null
              ? _errorBox(cs, dbErrorText(_tableError!))
              : page == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : ResultGrid(
                  rows: page,
                  firstRow: _offset,
                  sortColumn: _sort,
                  ascending: _asc,
                  onSort: _sortBy,
                ),
        ),
      ],
    );
  }

  Widget _errorBox(ColorScheme cs, String text) => Container(
    key: const Key('sql-error'),
    margin: const EdgeInsets.all(12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: cs.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SelectableText(
      text,
      style: kMonoStyle.copyWith(color: cs.onErrorContainer),
    ),
  );

  Widget _queryBox(ColorScheme cs) {
    final r = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  runQuery,
            },
            child: TextField(
              key: const Key('sql-input'),
              controller: _query,
              minLines: 3,
              maxLines: 8,
              style: kMonoStyle.copyWith(fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'SQL (Ctrl+Enter runs it)',
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              FilledButton.icon(
                key: const Key('sql-run'),
                onPressed: _running ? null : runQuery,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Run'),
              ),
              const SizedBox(width: 12),
              if (_running)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              Expanded(
                child: Text(
                  _queryNote ?? '',
                  key: const Key('sql-note'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              // a phone: the export buttons scroll instead of overflowing
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _exportButtons(r != null && r.columns.isNotEmpty),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Divider(height: 1, color: cs.outlineVariant),
        Expanded(
          child: _queryError != null
              ? Align(
                  alignment: Alignment.topLeft,
                  child: _errorBox(cs, _queryError!),
                )
              : r == null || r.columns.isEmpty
              ? const SizedBox.shrink()
              : ResultGrid(rows: r),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sel = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_s.readOnly)
          Container(
            key: const Key('data-readonly'),
            color: cs.tertiaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              'Read-only: ${_s.readOnlyWhy}',
              style: TextStyle(fontSize: 12, color: cs.onTertiaryContainer),
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 600 ? 140 : 230,
                child: Material(
                  color: cs.surfaceContainerLowest,
                  child: _sidebar(cs),
                ),
              ),
              VerticalDivider(width: 1, color: cs.outlineVariant),
              Expanded(
                child: sel == null ? _queryBox(cs) : _tableBrowser(cs, sel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
