// lib/visualizations/density_spectrum.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// Inspired by sci-fi / video camera waveform monitors.
/// Breaks the spectrum into columns of horizontal scanlines that cluster 
/// tightly at the peak, with a faint translucent fill underneath.
class DensitySpectrum implements Visualization {
  static const int barCount = 128;
  static const double smoothing = 0.6; // Slightly faster for techy energy
  static const double loHz = 20.0;
  static const double hiHz = 16000.0;

  final List<double> _levels = List<double>.filled(barCount, 0.0);

  @override
  String get name => 'Density Spectrum';

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
    
    final double tSm = math.pow(smoothing, 30.0 * ctx.dt).toDouble();

    final double maxH = h - (WaveformStyle.edgeMargin * 2);
    final double barW = w / barCount;
    // Overlap the dashes slightly horizontally to create a continuous glowing smear
    final double dashW = barW * 1.5; 
    // Uncapped thickness! Scales fully with the slider, with a minimum of 1.0px
    final double dashH = math.max(1.0, 2.0 * s.strokeScale);
    final double bottomY = h - WaveformStyle.edgeMargin;

    // The faint fill under the scanlines
    final ui.Paint fillPaint = ui.Paint()
      ..style = ui.PaintingStyle.fill
      ..color = ui.Color(s.outerColor).withOpacity(0.15);

    for (int b = 0; b < barCount; b++) {
      final double f0 = math.exp(logLo + (logHi - logLo) * b / barCount);
      final double f1 = math.exp(logLo + (logHi - logLo) * (b + 1) / barCount);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }

      double level = (math.pow(peak, 0.55).toDouble() * ctx.dampening).clamp(0.0, 1.0);
      _levels[b] = _levels[b] * tSm + level * (1.0 - tSm);
      
      if (_levels[b] < 0.01) continue;

      final double x = b * barW;
      final double peakY = bottomY - (_levels[b] * maxH);

      // 1. Draw the faint vertical fill to ground the wave
      canvas.drawRect(
        ui.Rect.fromLTWH(x + (barW * 0.1), peakY, barW * 0.8, bottomY - peakY), 
        fillPaint
      );
      
      // 2. Calculate how many scanline ticks to draw based on amplitude
      final int maxDots = 35;
      final int numDots = (_levels[b] * maxDots).round().clamp(1, maxDots);

      for(int d = 0; d < numDots; d++) {
        // t goes exactly from 0.0 (bottom) to 1.0 (top peak)
        double t = numDots > 1 ? d / (numDots - 1) : 1.0;
        
        // Easing out cubic curve: forces lines to cluster at the top 
        // without leaving a massive empty gap at the bottom
        double yRatio = 1.0 - math.pow(1.0 - t, 2.5).toDouble();
        
        double y = bottomY - (yRatio * _levels[b] * maxH);

        // Top is opaque/dense, bottom is highly transparent
        double opacity = math.pow(t, 1.5).toDouble(); 
        
        ui.Paint tickPaint;
        if (d == numDots - 1) { // The absolute peak gets the bright core color
          tickPaint = ui.Paint()..color = ui.Color(s.coreColor);
          if (s.glowBlurSigma > 0.0) {
            tickPaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
          }
        } else {
          tickPaint = ui.Paint()..color = ui.Color(s.midColor).withOpacity((opacity * 0.8).clamp(0.0, 1.0));
        }

        canvas.drawRect(
          ui.Rect.fromLTWH(x - (dashW - barW) / 2, y, dashW, dashH), 
          tickPaint
        );
      }
    }
  }
}