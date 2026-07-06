// ./lib/visualizations/phosphor_waveform.dart

import 'dart:math' as math;
import 'dart:ui' as ui;
import '../visualization.dart';

/// The original Ananogram oscilloscope: AGC'd time-domain waveform
/// with triple-stroke phosphor glow.
class PhosphorWaveform implements Visualization {
  double _peakSmoothed = 1.0;

  @override
  String get name => 'Phosphor Waveform';

  @override
  void reset() => _peakSmoothed = 1.0;

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final int width = ctx.width;
    final double height = ctx.height.toDouble();

    int start = ctx.sampleIndexAt(ctx.t);
    int end = ctx.sampleIndexAt(ctx.t + ctx.settings.windowDuration);

    final int chunkLen = end - start;
    if (chunkLen < 4 || width < 2) return;

    final double mid = height / 2.0;
    final double step = (chunkLen - 1) / (width - 1);

    // First pass: peak of the resampled window.
    double currentPeak = 0.0;
    for (int x = 0; x < width; x++) {
      final int idx = start + (x * step).toInt();
      double v = ctx.audio[idx];
      if (v.isNaN || v.isInfinite) v = 0.0;
      final double a = v.abs();
      if (a > currentPeak) currentPeak = a;
    }
    currentPeak += 1e-8;

    final double tSm = math.pow(WaveformStyle.agcSmoothing, 30.0 * ctx.dt).toDouble();
    _peakSmoothed = _peakSmoothed * tSm + currentPeak * (1.0 - tSm);
    
    if (_peakSmoothed < WaveformStyle.peakFloor) {
      _peakSmoothed = WaveformStyle.peakFloor;
    }

    final double gain = (1.0 / _peakSmoothed)
            .clamp(WaveformStyle.gainMin, WaveformStyle.gainMax) *
        ctx.dampening;

    // Second pass: path.
    final double yMin = WaveformStyle.edgeMargin;
    final double yMax = height - WaveformStyle.edgeMargin;

    final ui.Path path = ui.Path();
    for (int x = 0; x < width; x++) {
      final int idx = start + (x * step).toInt();
      double v = ctx.audio[idx];
      if (v.isNaN || v.isInfinite) v = 0.0;
      v = v.clamp(-1.0, 1.0);
      final double y = (mid - v * mid * gain).clamp(yMin, yMax);
      if (x == 0) {
        path.moveTo(0, y);
      } else {
        path.lineTo(x.toDouble(), y);
      }
    }

    _strokeGlow(canvas, path, ctx.settings);
  }

  static void _strokeGlow(ui.Canvas canvas, ui.Path path, WaveformSettings s) {
    final double scale = s.strokeScale;

    final ui.Paint outer = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = WaveformStyle.outerWidth * scale
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..color = ui.Color(s.outerColor);
    if (s.glowBlurSigma > 0.0) {
      outer.maskFilter =
          ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
    }

    final ui.Paint midP = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = WaveformStyle.midWidth * scale
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..color = ui.Color(s.midColor);

    final ui.Paint core = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = WaveformStyle.coreWidth * scale
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..color = ui.Color(s.coreColor);

    canvas.drawPath(path, outer);
    canvas.drawPath(path, midP);
    canvas.drawPath(path, core);
  }
}