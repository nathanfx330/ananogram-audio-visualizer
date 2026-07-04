// ./lib/visualizer_painter.dart
//
// Live-view painter: blits the compositor's retained image over a
// black background. All per-frame computation happens in the ticker.

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

class VizBlitPainter extends CustomPainter {
  final ui.Image? frame;
  final int repaintKey;

  const VizBlitPainter({required this.frame, required this.repaintKey});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF000000),
    );
    if (frame != null) {
      canvas.drawImage(frame!, Offset.zero, Paint());
    }
  }

  @override
  bool shouldRepaint(VizBlitPainter old) =>
      old.repaintKey != repaintKey || old.frame != frame;
}