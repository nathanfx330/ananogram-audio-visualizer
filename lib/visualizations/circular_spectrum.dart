// ./lib/visualizations/circular_spectrum.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// A radial frequency spectrum where low frequencies start at the top 
/// and wrap around a circle.
class CircularSpectrum implements Visualization {
  static const int barCount = 128;
  static const double smoothing = 0.65;
  static const double minRadiusRatio = 0.2; // Hollow center
  
  final List<double> _levels = List<double>.filled(barCount, 0.0);

  @override
  String get name => 'Circular Spectrum';

  @override
  void reset() {
    for (int i = 0; i < barCount; i++) _levels[i] = 0.0;
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final double maxRadius = math.min(w, h) / 2.0 * 0.9; 
    final double baseRadius = maxRadius * minRadiusRatio;

    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    // Log-spaced edges for a more musical frequency distribution
    final double logLo = math.log(20.0);
    final double logHi = math.log(16000.0);

    final WaveformSettings s = ctx.settings;
    
    final ui.Paint linePaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = (2.0 * s.strokeScale).clamp(1.0, 10.0)
      ..strokeCap = ui.StrokeCap.round
      ..color = ui.Color(s.midColor);

    if (s.glowBlurSigma > 0.0) {
      linePaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
    }

    canvas.save();
    canvas.translate(w / 2, h / 2); // Move origin to center

    for (int b = 0; b < barCount; b++) {
      final double f0 = math.exp(logLo + (logHi - logLo) * b / barCount);
      final double f1 = math.exp(logLo + (logHi - logLo) * (b + 1) / barCount);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }

      double level = (math.pow(peak, 0.6).toDouble() * ctx.dampening).clamp(0.0, 1.0);
      _levels[b] = _levels[b] * smoothing + level * (1.0 - smoothing);
      
      final double barLength = _levels[b] * (maxRadius - baseRadius);
      if (barLength < 1.0) continue;

      // Calculate angle (top center, moving clockwise)
      final double angle = (b / barCount) * 2 * math.pi - (math.pi / 2);
      
      final double cosA = math.cos(angle);
      final double sinA = math.sin(angle);

      final ui.Offset startPoint = ui.Offset(cosA * baseRadius, sinA * baseRadius);
      final ui.Offset endPoint = ui.Offset(cosA * (baseRadius + barLength), sinA * (baseRadius + barLength));

      canvas.drawLine(startPoint, endPoint, linePaint);
    }

    canvas.restore();
  }
}