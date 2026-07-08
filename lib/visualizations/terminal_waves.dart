// ./lib/visualizations/terminal_waves.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../visualization.dart';

class _WaveDef {
  final double freq;
  final double speed;
  final int colorType; // 0 = outer, 1 = mid, 2 = core
  
  const _WaveDef({
    required this.freq,
    required this.speed,
    required this.colorType,
  });
}

/// Combines a Siri-like multi-wave effect with a Fallout Pip-Boy / Terminal 
/// ASCII aesthetic. Uses complex harmonic interference waves driven by fluid 
/// frequency bands. Freezes perfectly when audio pauses.
class TerminalWaves implements Visualization {
  double _phase = 0.0;
  double _lastT = -1.0;

  // Smoothing trackers for the distinct frequency bands
  double _smoothBass = 0.0;
  double _smoothMid = 0.0;
  double _smoothTreb = 0.0;

  @override
  String get name => 'Terminal Waves';

  @override
  void reset() {
    _phase = 0.0;
    _lastT = -1.0;
    _smoothBass = 0.0;
    _smoothMid = 0.0;
    _smoothTreb = 0.0;
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;

    // 1. Calculate true time delta so it freezes perfectly on pause/scrub
    double actualDt = 0.0;
    if (_lastT >= 0.0 && ctx.t >= _lastT) {
      actualDt = ctx.t - _lastT;
    }
    _lastT = ctx.t;

    // 2. Sample REAL frequency bands
    double rawBass = (math.pow(ctx.bass * 2.0, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);
    double rawMid  = (math.pow(ctx.midBand * 2.5, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);
    double rawTreb = (math.pow(ctx.treb * 3.0, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);

    // FLUID SMOOTHING: No more jitter. This creates a very fluid, musical bounce.
    final double tSm = math.pow(0.65, 30.0 * ctx.dt).toDouble();
    
    _smoothBass = _smoothBass * tSm + rawBass * (1.0 - tSm);
    _smoothMid  = _smoothMid  * tSm + rawMid  * (1.0 - tSm);
    _smoothTreb = _smoothTreb * tSm + rawTreb * (1.0 - tSm);

    // 3. Advance phase (horizontal drift).
    // Uses actualDt (0 when paused). Has a tiny baseline drift (0.2) when playing, 
    // but accelerates smoothly when the audio gets loud.
    double totalEnergy = (_smoothBass + _smoothMid + _smoothTreb) / 3.0;
    _phase += actualDt * (0.2 + (totalEnergy * 6.0));

    // 4. Define the Terminal Grid
    final double blockSize = (8.0 * s.strokeScale).clamp(4.0, 32.0);
    final int cols = (w / blockSize).floor();
    final int rows = (h / blockSize).floor();
    
    if (cols < 2 || rows < 2) return;

    final double xOffset = (w - (cols * blockSize)) / 2.0;
    final double yOffset = (h - (rows * blockSize)) / 2.0;

    // 5. Define our Siri waves
    const List<_WaveDef> waves = [
      _WaveDef(freq: 0.8, speed: -1.0, colorType: 0), // Outer 1
      _WaveDef(freq: 1.2, speed:  1.3, colorType: 0), // Outer 2
      _WaveDef(freq: 1.7, speed: -1.6, colorType: 1), // Mid
      _WaveDef(freq: 2.1, speed:  1.9, colorType: 2), // Core
    ];

    // Setup Additive Blending paints for the hot-spots
    final List<ui.Paint> fillPaints = [];
    final List<ui.Paint> capPaints = [];

    for (int color in [s.outerColor, s.midColor, s.coreColor]) {
      final ui.Paint fill = ui.Paint()
        ..color = ui.Color(color).withOpacity(0.15)
        ..style = ui.PaintingStyle.fill
        ..blendMode = ui.BlendMode.plus;
      
      final ui.Paint cap = ui.Paint()
        ..color = ui.Color(color).withOpacity(0.7)
        ..style = ui.PaintingStyle.fill
        ..blendMode = ui.BlendMode.plus;

      if (s.glowBlurSigma > 0.0) {
        fill.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
        cap.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
      }

      fillPaints.add(fill);
      capPaints.add(cap);
    }

    // 6. Draw the distinct, intersecting, COMPLEX waves
    for (int wIdx = 0; wIdx < waves.length; wIdx++) {
      final wave = waves[wIdx];
      final ui.Paint fillPaint = fillPaints[wave.colorType];
      final ui.Paint capPaint = capPaints[wave.colorType];
      
      // Tie the amplitude of this specific wave to a real audio band
      double waveAmp = 0.05; // tiny baseline so it never completely vanishes
      if (wIdx == 0) waveAmp += _smoothBass; // Wide wave = Bass
      if (wIdx == 1) waveAmp += _smoothMid;  // Medium wave = Vocals
      if (wIdx == 2) waveAmp += _smoothMid;  // Medium wave = Vocals
      if (wIdx == 3) waveAmp += _smoothTreb; // Tight wave = Treble
      waveAmp = waveAmp.clamp(0.0, 1.0);

      for (int c = 0; c < cols; c++) {
        double nx = c / (cols - 1);
        
        // Siri Envelope: pinched at the edges, open in the middle
        double envelope = math.pow(math.sin(nx * math.pi), 1.2).toDouble();
        
        // COMPLEXITY FIX: Harmonic Interference
        // Instead of one boring sine wave, we calculate a primary wave, and add a smaller, 
        // faster secondary wave moving in the OPPOSITE direction. This creates a highly 
        // complex, organic, rippling shape.
        double p1 = _phase * wave.speed;
        double p2 = _phase * wave.speed * -1.4; // Counter-rotating harmonic

        double v1 = math.sin(nx * math.pi * 2.0 * wave.freq + p1);
        double v2 = math.sin(nx * math.pi * 4.3 * wave.freq + p2) * 0.35;
        
        // Normalize the combined waves back to roughly [-1.0, 1.0]
        double sineVal = (v1 + v2) / 1.35;
        
        // Push UP from the bottom
        double upVal = (sineVal + 1.0) / 2.0;
        
        // Calculate block row displacement
        double displacement = upVal * waveAmp * envelope * (rows * 0.95);
        int peakRow = (rows - 1) - displacement.round().clamp(0, rows - 1);
        
        // Draw the vertical column down to the bottom
        for (int drawR = peakRow; drawR < rows; drawR++) {
          double bx = xOffset + c * blockSize;
          double by = yOffset + drawR * blockSize;
          
          canvas.drawRect(
            ui.Rect.fromLTWH(bx + 1, by + 1, blockSize - 2, blockSize - 2),
            drawR == peakRow ? capPaint : fillPaint,
          );
        }
      }
    }
  }
}