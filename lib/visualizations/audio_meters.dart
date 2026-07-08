// ./lib/visualizations/audio_meters.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../visualization.dart';

/// A professional dual-channel segmented LED audio meter.
/// Currently driven by mono (L and R identical), but architected
/// with independent states ready for true stereo input.
class AudioMeters implements Visualization {
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
  String get name => 'Audio Meters';

  @override
  void reset() {
    _levelL = 0.0;
    _levelR = 0.0;
    _peakHoldL = 0.0;
    _peakHoldR = 0.0;
    _peakTimerL = 0.0;
    _peakTimerR = 0.0;
  }

  // Pure deterministic state advancement
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
    final double meterWidth = (w * 0.08).clamp(20.0, 150.0);
    final double gapX = w * 0.02;
    final double startX_L = (w / 2) - (gapX / 2) - meterWidth;
    final double startX_R = (w / 2) + (gapX / 2);

    final double startY = WaveformStyle.edgeMargin;
    final double maxH = h - (WaveformStyle.edgeMargin * 2);
    final double segH = maxH / segments;
    final double segGap = segH * 0.15; // Gap between LEDs

    _drawMeter(canvas, s, startX_L, startY, meterWidth, maxH, segH, segGap, _levelL, _peakHoldL);
    _drawMeter(canvas, s, startX_R, startY, meterWidth, maxH, segH, segGap, _levelR, _peakHoldR);
  }

  void _drawMeter(ui.Canvas canvas, WaveformSettings s, double x, double y, 
                  double w, double h, double segH, double gap, double level, double peakHold) {
    
    int litSegments = (level * segments).round();
    int peakSegment = (peakHold * segments).round().clamp(0, segments - 1);

    for (int i = 0; i < segments; i++) {
      // Draw from bottom to top
      double segY = (y + h) - ((i + 1) * segH);
      ui.Rect rect = ui.Rect.fromLTWH(x, segY + gap/2, w, segH - gap);

      // Map color based on height: Bottom 65% Outer, Next 25% Mid, Top 10% Core
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