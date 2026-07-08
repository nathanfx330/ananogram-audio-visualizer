// ./lib/visualizations/horizontal_meters.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../visualization.dart';

/// A professional dual-channel segmented LED audio meter (Horizontal).
/// Left channel is on top, Right channel is on the bottom.
class HorizontalMeters implements Visualization {
  static const int segments = 50;
  
  // Independent L/R levels
  double _levelL = 0.0;
  double _levelR = 0.0;
  
  // Peak hold states
  double _peakHoldL = 0.0;
  double _peakHoldR = 0.0;
  double _peakTimerL = 0.0;
  double _peakTimerR = 0.0;

  @override
  String get name => 'Horizontal Meters';

  @override
  void reset() {
    _levelL = 0.0;
    _levelR = 0.0;
    _peakHoldL = 0.0;
    _peakHoldR = 0.0;
    _peakTimerL = 0.0;
    _peakTimerR = 0.0;
  }

  // Pure deterministic state advancement (identical ballistics to vertical)
  void _advance(VizContext ctx) {
    int start = ctx.sampleIndexAt(ctx.t);
    int end = ctx.sampleIndexAt(ctx.t + ctx.settings.windowDuration);
    final int chunkLen = end - start;
    if (chunkLen < 4) return;

    // Scan for peak in the current window
    double peak = 0.0;
    for (int i = 0; i < chunkLen; i++) {
      int idx = start + i;
      double v = idx < ctx.audio.length ? ctx.audio[idx].abs() : 0.0;
      if (v > peak) peak = v;
    }

    // Apply user dampening and perceptual curve
    double targetLevel = (math.pow(peak, 0.7).toDouble() * ctx.dampening).clamp(0.0, 1.0);

    // Future-proofing: When VizContext gets stereo support, change to calculateLeft/Right
    double targetL = targetLevel;
    double targetR = targetLevel;

    // Ballistics: Fast attack, slower release
    final double attackSm = math.pow(0.2, 30.0 * ctx.dt).toDouble();
    final double releaseSm = math.pow(0.85, 30.0 * ctx.dt).toDouble();

    _levelL = targetL > _levelL 
        ? _levelL * attackSm + targetL * (1.0 - attackSm)
        : _levelL * releaseSm + targetL * (1.0 - releaseSm);
        
    _levelR = targetR > _levelR 
        ? _levelR * attackSm + targetR * (1.0 - attackSm)
        : _levelR * releaseSm + targetR * (1.0 - releaseSm);

    // Peak Hold logic (Hold for 1 second, then drop fast)
    _peakTimerL += ctx.dt;
    if (targetL >= _peakHoldL) {
      _peakHoldL = targetL;
      _peakTimerL = 0.0;
    } else if (_peakTimerL > 1.0) {
      _peakHoldL = _peakHoldL * releaseSm; // Fall off
    }

    _peakTimerR += ctx.dt;
    if (targetR >= _peakHoldR) {
      _peakHoldR = targetR;
      _peakTimerR = 0.0;
    } else if (_peakTimerR > 1.0) {
      _peakHoldR = _peakHoldR * releaseSm;
    }
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;

    // Layout
    final double meterHeight = (h * 0.08).clamp(20.0, 100.0);
    final double gapY = h * 0.04;
    
    // Position Top (Left Channel) and Bottom (Right Channel)
    final double startY_L = (h / 2) - (gapY / 2) - meterHeight;
    final double startY_R = (h / 2) + (gapY / 2);

    // Margins on the sides
    final double startX = w * 0.05; 
    final double maxW = w * 0.90; 
    
    final double segW = maxW / segments;
    final double segGap = segW * 0.15; // Gap between LEDs

    _drawMeter(canvas, s, startX, startY_L, maxW, meterHeight, segW, segGap, _levelL, _peakHoldL);
    _drawMeter(canvas, s, startX, startY_R, maxW, meterHeight, segW, segGap, _levelR, _peakHoldR);
  }

  void _drawMeter(ui.Canvas canvas, WaveformSettings s, double x, double y, 
                  double w, double h, double segW, double gap, double level, double peakHold) {
    
    int litSegments = (level * segments).round();
    int peakSegment = (peakHold * segments).round().clamp(0, segments - 1);

    for (int i = 0; i < segments; i++) {
      // Draw from left to right
      double segX = x + (i * segW);
      ui.Rect rect = ui.Rect.fromLTWH(segX + gap/2, y, segW - gap, h);

      // Map color based on width: Left 65% Outer, Next 25% Mid, Right 10% Core
      ui.Color activeColor;
      if (i < segments * 0.65) {
        activeColor = ui.Color(s.outerColor);
      } else if (i < segments * 0.90) {
        activeColor = ui.Color(s.midColor);
      } else {
        activeColor = ui.Color(s.coreColor);
      }

      final ui.Paint paint = ui.Paint()..style = ui.PaintingStyle.fill;

      if (i < litSegments || i == peakSegment) {
        // Active LED
        paint.color = activeColor;
        if (s.glowBlurSigma > 0.0) {
          paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
        }
        canvas.drawRect(rect, paint);

        // Core bright center for active segments
        final ui.Paint corePaint = ui.Paint()
          ..style = ui.PaintingStyle.fill
          ..color = ui.Color(s.coreColor).withOpacity(0.5);
        canvas.drawRect(rect.deflate(2.0), corePaint);
      } else {
        // Dim/Inactive LED
        paint.color = ui.Color(s.outerColor).withOpacity(0.1);
        canvas.drawRect(rect, paint);
      }
    }
  }
}