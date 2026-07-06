// ./lib/visualizations/dot_matrix.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// An LED/VFD style dot matrix equalizer.
class DotMatrixSpectrum implements Visualization {
  static const int columns = 48;
  static const int rows = 24;
  static const double smoothing = 0.8;
  final List<double> _levels = List<double>.filled(columns, 0.0);

  @override
  String get name => 'Dot Matrix';

  @override
  void reset() {
    for (int i = 0; i < columns; i++) _levels[i] = 0.0;
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    final double logLo = math.log(20.0);
    final double logHi = math.log(16000.0);
    final WaveformSettings s = ctx.settings;
    
    final double tSm = math.pow(smoothing, 30.0 * ctx.dt).toDouble();

    // Calculate grid spacing
    final double dotSize = (w / columns) * 0.6;
    final double xGap = (w - (dotSize * columns)) / (columns + 1);
    final double yGap = (h - (dotSize * rows)) / (rows + 1);

    final ui.Paint activePaint = ui.Paint()..color = ui.Color(s.coreColor);
    if (s.glowBlurSigma > 0.0) {
      activePaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
    }
    
    // Dim paint for the "off" LEDs
    final ui.Paint inactivePaint = ui.Paint()
      ..color = ui.Color(s.outerColor).withOpacity(0.15)
      ..style = ui.PaintingStyle.fill;

    for (int c = 0; c < columns; c++) {
      final double f0 = math.exp(logLo + (logHi - logLo) * c / columns);
      final double f1 = math.exp(logLo + (logHi - logLo) * (c + 1) / columns);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }

      double level = (math.pow(peak, 0.55).toDouble() * ctx.dampening).clamp(0.0, 1.0);
      _levels[c] = _levels[c] * tSm + level * (1.0 - tSm);

      final int litRows = (_levels[c] * rows).round();
      final double x = xGap + c * (dotSize + xGap);

      for (int r = 0; r < rows; r++) {
        // Draw from bottom to top
        final double y = h - (yGap + r * (dotSize + yGap)) - dotSize;
        final ui.Rect dotRect = ui.Rect.fromLTWH(x, y, dotSize, dotSize);
        
        // If the row index is less than litRows, turn the LED "on"
        if (r < litRows) {
          canvas.drawOval(dotRect, activePaint);
        } else {
          canvas.drawOval(dotRect, inactivePaint);
        }
      }
    }
  }
}