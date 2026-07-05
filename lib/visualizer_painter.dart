// ./lib/visualizer_painter.dart
//
// Live-view painter: blits the compositor's retained image over a
// configurable background. All per-frame computation happens in the ticker.

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

class VizBlitPainter extends CustomPainter {
  final ui.Image? frame;
  final int repaintKey;
  final Color backgroundColor;

  const VizBlitPainter({
    required this.frame, 
    required this.repaintKey,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );
    if (frame != null) {
      canvas.drawImage(frame!, Offset.zero, Paint());
    }
  }

  @override
  bool shouldRepaint(VizBlitPainter old) =>
      old.repaintKey != repaintKey || 
      old.frame != frame ||
      old.backgroundColor != backgroundColor;
}