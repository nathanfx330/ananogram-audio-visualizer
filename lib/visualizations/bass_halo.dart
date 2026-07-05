// ./lib/visualizations/bass_halo.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../visualization.dart';

/// A sleek, minimalist circular waveform that throbs to the bass.
class BassHalo implements Visualization {
  double _smoothBass = 0.0;

  @override
  String get name => 'Minimalist Halo';

  @override
  void reset() {
    _smoothBass = 0.0;
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;

    // Smooth the bass band energy
    _smoothBass = _smoothBass * 0.8 + (ctx.bass * 2.0) * 0.2;
    _smoothBass = _smoothBass.clamp(0.0, 1.0);

    // Base radius scales with bass
    final double minRadius = math.min(w, h) * 0.25;
    final double maxRadius = math.min(w, h) * 0.40;
    final double currentRadius = minRadius + (_smoothBass * (maxRadius - minRadius));

    // Get waveform chunk
    int start = ctx.sampleIndexAt(ctx.t);
    int end = ctx.sampleIndexAt(ctx.t + s.windowDuration);
    final int chunkLen = end - start;
    if (chunkLen < 4) return;

    final ui.Path path = ui.Path();
    final int points = 360; 
    final double step = chunkLen / points;
    final double rippleScale = (maxRadius * 0.2) * ctx.dampening; // How big the waveform spikes are

    for (int i = 0; i <= points; i++) {
      // Modulo prevents out-of-bounds at the very end to close the loop
      final int idx = start + (i * step).toInt().clamp(0, chunkLen - 1);
      
      // We apply a sine window to the waveform so it crossfades perfectly at the 12 o'clock seam
      final double window = math.sin((i / points) * math.pi);
      
      double v = idx < ctx.audio.length ? ctx.audio[idx] : 0.0;
      if (v.isNaN || v.isInfinite) v = 0.0;
      v = v.clamp(-1.0, 1.0) * window;

      final double angle = (i / points) * 2 * math.pi - (math.pi / 2);
      final double r = currentRadius + (v * rippleScale);

      final double px = (w / 2) + math.cos(angle) * r;
      final double py = (h / 2) + math.sin(angle) * r;

      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    path.close();

    // Draw the glow and core
    final ui.Paint outer = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 6.0 * s.strokeScale
      ..color = ui.Color(s.outerColor);
    if (s.glowBlurSigma > 0.0) {
      outer.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma * 2);
    }
    
    final ui.Paint core = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2.0 * s.strokeScale
      ..color = ui.Color(s.coreColor);

    canvas.drawPath(path, outer);
    canvas.drawPath(path, core);
  }
}