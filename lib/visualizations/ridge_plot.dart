// ./lib/visualizations/ridge_plot.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// A pseudo-3D scrolling history of the spectrum.
/// Often called a Waterfall or Ridge plot.
class RidgePlotSpectrum implements Visualization {
  static const int historySize = 40;
  static const int points = 64;
  final List<List<double>> _history = [];

  @override
  String get name => 'Ridge Plot (Waterfall)';

  @override
  void reset() {
    _history.clear();
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    // 1. Process current frame into `points` number of bins
    List<double> currentLine = List.filled(points, 0.0);
    final double logLo = math.log(20.0);
    final double logHi = math.log(12000.0);

    for (int b = 0; b < points; b++) {
      final double f0 = math.exp(logLo + (logHi - logLo) * b / points);
      final double f1 = math.exp(logLo + (logHi - logLo) * (b + 1) / points);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }
      currentLine[b] = (math.pow(peak, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);
    }

    // 2. Add to history, remove oldest
    _history.insert(0, currentLine);
    if (_history.length > historySize) {
      _history.removeLast();
    }

    // 3. Draw from back to front to get proper occlusion (3D effect)
    final WaveformSettings s = ctx.settings;
    final double lineSpacing = h / (historySize + 10);
    final double maxSpike = lineSpacing * 8.0;

    // Use the dynamic background color to hide lines behind it properly
    final ui.Paint fillPaint = ui.Paint()..color = ui.Color(s.backgroundColor); 
    final ui.Paint strokePaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = (1.5 * s.strokeScale).clamp(1.0, 5.0)
      ..color = ui.Color(s.midColor);

    for (int i = _history.length - 1; i >= 0; i--) {
      final List<double> lineData = _history[i];
      // Perspective offset (shift X and Y as it goes back in time)
      final double yBase = h - (i * lineSpacing) - WaveformStyle.edgeMargin;
      final double xOffset = i * (w * 0.005); 
      final double rowWidth = w - (historySize * w * 0.005);
      final double step = rowWidth / (points - 1);

      final ui.Path path = ui.Path();
      path.moveTo(xOffset, yBase);

      for (int p = 0; p < points; p++) {
        final double x = xOffset + (p * step);
        // Smooth out the edges so the line doesn't abruptly snap to the sides
        final double edgeFade = math.sin((p / (points - 1)) * math.pi);
        final double y = yBase - (lineData[p] * maxSpike * edgeFade);
        path.lineTo(x, y);
      }

      // Drop down to the bottom corners to create a solid fill shape
      final ui.Path fillPath = ui.Path.from(path);
      fillPath.lineTo(xOffset + rowWidth, yBase + lineSpacing);
      fillPath.lineTo(xOffset, yBase + lineSpacing);
      fillPath.close();

      canvas.drawPath(fillPath, fillPaint);
      canvas.drawPath(path, strokePaint);
    }
  }
}