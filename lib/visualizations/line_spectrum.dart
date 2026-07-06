// ./lib/visualizations/line_spectrum.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// A continuous, smooth line graph of the frequency spectrum.
/// Draws a flowing curve from bass (left) to treble (right) using
/// the triple-stroke phosphor glow style.
class LineSpectrum implements Visualization {
  static const int pointCount = 128;
  static const double smoothing = 0.65;
  static const double loHz = 20.0;
  static const double hiHz = 16000.0;

  final List<double> _levels = List<double>.filled(pointCount, 0.0);

  @override
  String get name => 'Line Spectrum';

  @override
  void reset() {
    for (int i = 0; i < pointCount; i++) {
      _levels[i] = 0.0;
    }
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    final double logLo = math.log(loHz);
    final double logHi = math.log(hiHz);
    final WaveformSettings s = ctx.settings;
    
    final double maxH = h - (WaveformStyle.edgeMargin * 2);
    final double stepX = w / (pointCount - 1);
    
    final double tSm = math.pow(smoothing, 30.0 * ctx.dt).toDouble();

    for (int p = 0; p < pointCount; p++) {
      final double f0 = math.exp(logLo + (logHi - logLo) * p / pointCount);
      final double f1 = math.exp(logLo + (logHi - logLo) * (p + 1) / pointCount);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }

      double level = (math.pow(peak, 0.55).toDouble() * ctx.dampening).clamp(0.0, 1.0);
      _levels[p] = _levels[p] * tSm + level * (1.0 - tSm);
    }

    // Build the continuous path
    final ui.Path path = ui.Path();
    for (int p = 0; p < pointCount; p++) {
      final double x = p * stepX;
      final double y = h - WaveformStyle.edgeMargin - (_levels[p] * maxH);

      if (p == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    _strokeGlow(canvas, path, s);
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
      outer.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
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