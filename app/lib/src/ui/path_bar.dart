// The frame of the path bar: Back, Forward and Up, the breadcrumbs (a
// click on the free space or Ctrl+L makes them an editable path) and the
// search box of the folder.

import 'package:flutter/material.dart';

/// The editable path of the path bar: its text and what Enter does.
class PathEdit extends ChangeNotifier {
  bool _editing = false;
  String Function() text;
  Future<void> Function(String path) onSubmit;

  /// Called when the editing ends (the focus goes back to the list).
  VoidCallback? onDone;
  PathEdit({required this.text, required this.onSubmit, this.onDone});

  bool get editing => _editing;
  set editing(bool v) {
    if (v == _editing) return;
    _editing = v;
    notifyListeners();
    if (!v) onDone?.call();
  }
}

/// One breadcrumb.
Widget crumbButton(
  BuildContext context, {
  required Key key,
  required String label,
  VoidCallback? onTap,
  IconData? icon,
  Color? iconColor,
  bool current = false,
  String? tooltip,
  double maxWidth = 280,
  bool bold = true,
}) {
  final cs = Theme.of(context).colorScheme;
  Widget w = InkWell(
    key: key,
    borderRadius: BorderRadius.circular(6),
    onTap: current ? null : onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 4),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: current && bold
                    ? FontWeight.w600
                    : FontWeight.normal,
                color: current ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  if (tooltip != null) w = Tooltip(message: tooltip, child: w);
  return w;
}

Widget crumbSeparator(BuildContext context) => Icon(
  Icons.chevron_right_rounded,
  size: 16,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);

class PathBarFrame extends StatelessWidget {
  final List<Widget> crumbs;
  final PathEdit? edit;
  final bool compact;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onUp;
  final String backTooltip;
  final String upTooltip;
  final TextEditingController filter;
  final FocusNode filterFocus;
  final String filterHint;
  final bool filterActive;
  final void Function(String text) onFilter;

  /// Enter in the search box (the recursive search).
  final void Function(String text)? onFilterSubmit;

  /// After the search box (the recursive search switch).
  final Widget? trailing;

  const PathBarFrame({
    super.key,
    required this.crumbs,
    required this.edit,
    required this.compact,
    required this.onBack,
    required this.onForward,
    required this.onUp,
    required this.backTooltip,
    required this.upTooltip,
    required this.filter,
    required this.filterFocus,
    required this.filterHint,
    required this.filterActive,
    required this.onFilter,
    this.onFilterSubmit,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = edit;
    final box = Container(
      height: compact ? 36 : 32,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: e == null
          ? _Crumbs(crumbs: crumbs, onEmpty: null)
          : ListenableBuilder(
              listenable: e,
              builder: (context, _) => e.editing
                  ? _PathField(edit: e)
                  : _Crumbs(crumbs: crumbs, onEmpty: () => e.editing = true),
            ),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: box,
      );
    }
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            key: const Key('nav-back'),
            tooltip: backTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
          ),
          IconButton(
            key: const Key('nav-forward'),
            tooltip: 'Forward (Alt+Right)',
            visualDensity: VisualDensity.compact,
            onPressed: onForward,
            icon: const Icon(Icons.arrow_forward_rounded, size: 20),
          ),
          IconButton(
            key: const Key('nav-up'),
            tooltip: upTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onUp,
            icon: const Icon(Icons.arrow_upward_rounded, size: 20),
          ),
          const SizedBox(width: 6),
          Expanded(child: box),
          const SizedBox(width: 8),
          SizedBox(
            width: 240,
            height: 32,
            child: TextField(
              key: const Key('filter'),
              controller: filter,
              focusNode: filterFocus,
              onChanged: onFilter,
              onSubmitted: onFilterSubmit,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: filterHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: !filterActive
                    ? null
                    : IconButton(
                        tooltip: 'Clear the filter',
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () {
                          filter.clear();
                          onFilter('');
                        },
                      ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Crumbs extends StatelessWidget {
  final List<Widget> crumbs;
  final VoidCallback? onEmpty;
  const _Crumbs({required this.crumbs, required this.onEmpty});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        key: const Key('crumbs'),
        behavior: HitTestBehavior.translucent,
        onTap: onEmpty,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: Row(children: crumbs),
          ),
        ),
      ),
    );
  }
}

class _PathField extends StatefulWidget {
  final PathEdit edit;
  const _PathField({required this.edit});

  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final _c = TextEditingController(text: widget.edit.text());
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.edit.editing = false;
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, e) {
        if (e.logicalKey.keyLabel == 'Escape') {
          widget.edit.editing = false;
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        key: const Key('path-field'),
        controller: _c,
        focusNode: _focus,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        ),
        onSubmitted: (v) {
          widget.edit.editing = false;
          widget.edit.onSubmit(v.trim());
        },
      ),
    );
  }
}
