// zx in the browser (https://x1watt.github.io/zx/online/): the read-only
// web version. The archives are read by the engine worker (the zx library
// compiled to WebAssembly, web/engine/); this UI only holds package:zx's
// client API (docs/architecture.md section 20). Built by tool/build_web.sh.

import 'package:flutter/material.dart';

import 'src/theme.dart';
import 'src/web/web_home.dart';

void main() {
  runApp(
    MaterialApp(
      title: 'zx',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const WebHome(),
    ),
  );
}
