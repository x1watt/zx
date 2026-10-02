// The look of the 80s theme: panes drawn as the windows of an early
// Macintosh desktop (a 1 pixel black frame, a hard drop shadow, a title
// bar with pinstripes, a close box, the title in a white gap) on the gray
// dithered desktop pattern.

import 'package:flutter/material.dart';

/// The gray desktop: a 2 by 2 black and white checker, repeated.
const kDesktopPattern = DecorationImage(
  image: AssetImage('assets/icon/desk-pattern.png'),
  repeat: ImageRepeat.repeat,
  filterQuality: FilterQuality.none,
  scale: 1,
);

class ClassicWindow extends StatelessWidget {
  final String title;
  final Widget child;
  const ClassicWindow({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border.fromBorderSide(BorderSide(color: Colors.black)),
        boxShadow: [BoxShadow(color: Colors.black, offset: Offset(2, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 22,
            child: CustomPaint(
              painter: const _Pinstripes(),
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  // the close box
                  Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.black),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Container(
                        color: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 23),
                ],
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1, color: Colors.black),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Six black lines across the title bar, one pixel apart.
class _Pinstripes extends CustomPainter {
  const _Pinstripes();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black;
    final top = (size.height - 11) / 2;
    for (var i = 0; i < 6; i++) {
      canvas.drawRect(
        Rect.fromLTWH(2, top.floorToDouble() + i * 2, size.width - 4, 1),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_Pinstripes old) => false;
}
