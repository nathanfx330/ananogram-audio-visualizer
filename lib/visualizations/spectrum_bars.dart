// ./lib/visualizations/spectrum_bars.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// Log-spaced spectrum bars, 20 Hz - 16 kHz, with per-bar exponential
/// smoothing and the same phosphor palette (glow body + bright cap).
class SpectrumBars implements Visualization {
  static const int barCount = 64;
  static const double smoothing = 0.7;   // old-value retention
  static const double loHz = 20.0;
  static const double hiHz = 16000.0;

  final List<double> _levels = List<double>.filled(barCount, 0.0);

  @override
  String get name => 'Spectrum Bars';

  @override
  void reset() {
    for (int i = 0; i < barCount; i++) {
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
    final double gap = 2.0;
    final double barW = (w - gap * (barCount - 1)) / barCount;
    final double maxBarH = h - 2 * WaveformStyle.edgeMargin;

    final ui.Paint body = ui.Paint()..color = ui.Color(s.midColor);
    if (s.glowBlurSigma > 0.0) {
      body.maskFilter =
          ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
    }
    final ui.Paint cap = ui.Paint()..color = ui.Color(s.coreColor);
    final double capH =
        (WaveformStyle.midWidth * s.strokeScale).clamp(1.0, 12.0);

    for (int b = 0; b < barCount; b++) {
      // Log-spaced band edges for this bar.
      final double f0 =
          math.exp(logLo + (logHi - logLo) * b / barCount);
      final double f1 =
          math.exp(logLo + (logHi - logLo) * (b + 1) / barCount);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }

      // Perceptual-ish curve + user dampening.
      double level =
          (math.pow(peak, 0.5).toDouble() * ctx.dampening)
              .clamp(0.0, 1.0);

      _levels[b] = _levels[b] * smoothing + level * (1.0 - smoothing);
      final double barH = _levels[b] * maxBarH;
      if (barH < 0.5) continue;

      final double x = b * (barW + gap);
      final double top = h - WaveformStyle.edgeMargin - barH;

      canvas.drawRect(ui.Rect.fromLTWH(x, top, barW, barH), body);
      canvas.drawRect(ui.Rect.fromLTWH(x, top, barW, capH), cap);
    }
  }
}