// The theme of the web version: chosen in the page (remembered in
// localStorage) or given by a link (#theme=green), which applies to that
// visit without changing the remembered choice.

import 'package:flutter/material.dart';

import '../theme.dart';
import 'web_services.dart';

class ThemeChoice extends ChangeNotifier {
  WebTheme _value;

  /// The theme the link gave, kept in the address until the reader picks
  /// another one.
  WebTheme? _linked;

  ThemeChoice._(this._value, this._linked);

  /// From the link, else the remembered choice, else dark.
  factory ThemeChoice.load() {
    final linked = WebTheme.byName(linkParameters().theme);
    return ThemeChoice._(
      linked ?? WebTheme.byName(storedTheme()) ?? WebTheme.dark,
      linked,
    );
  }

  WebTheme get value => _value;
  WebTheme? get linked => _linked;

  void choose(WebTheme t) {
    _value = t;
    _linked = null;
    storeTheme(t.name);
    notifyListeners();
  }
}

/// The faint horizontal lines of a CRT over the retro themes.
class Scanlines extends CustomPainter {
  final Color color;
  const Scanlines(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var y = 0.0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(Scanlines old) => old.color != color;
}
