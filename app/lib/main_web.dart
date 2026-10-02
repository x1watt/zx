// zx in the browser (https://x1watt.github.io/zx/online/): the read-only
// web version. The archives are read by the engine worker (the zx library
// compiled to WebAssembly, web/engine/); this UI only holds package:zx's
// client API (docs/architecture.md section 20). Built by tool/build_web.sh.

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/theme.dart';
import 'src/web/theme_choice.dart';
import 'src/web/web_home.dart';

void main() {
  // the page manages its address itself (links to archives, web_services)
  setUrlStrategy(null);
  final themes = ThemeChoice.load();
  runApp(
    ListenableBuilder(
      listenable: themes,
      builder: (context, _) {
        final t = themes.value;
        return MaterialApp(
          title: 'zx',
          debugShowCheckedModeBanner: false,
          theme: buildWebTheme(t),
          builder: (context, child) => !t.retro
              ? child!
              : Stack(
                  children: [
                    child!,
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: Scanlines(
                            Colors.black.withValues(alpha: 0.18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
          home: WebHome(themes: themes),
        );
      },
    ),
  );
}
