// ./lib/visualizations/vocal_telemetry.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../visualization.dart';

/// A forensic/analytical read-out designed for spoken word and documentary edits.
/// Acts like an EKG or polygraph: the "current" time is on the right, 
/// and the history of the voice scrolls away to the left.
/// Includes background telemetry grids and a dual-envelope display.
class VocalTelemetry implements Visualization {
  double _smoothMid = 0.0; // Tracks voice formants

  @override
  String get name => 'Vocal Telemetry (Forensic)';

  @override
  void reset() {
    _smoothMid = 0.0;
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;

    // Human speech lives heavily in the mid-band. We use this to modulate
    // the intensity of the playhead.
    _smoothMid = _smoothMid * 0.8 + (ctx.midBand * 2.0) * 0.2;
    _smoothMid = _smoothMid.clamp(0.0, 1.0);

    // --- 1. DRAW ANALYTICAL GRID ---
    final ui.Paint gridPaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = s.outerColor.withOpacity(0.3);

    // Draw horizontal measurement lines
    final int hLines = 8;
    for (int i = 1; i < hLines; i++) {
      final double y = (h / hLines) * i;
      canvas.drawLine(ui.Offset(0, y), ui.Offset(w, y), gridPaint);
    }

    // Draw vertical tick marks (moving with time to look like scrolling paper)
    final int vLines = 10;
    final double pixelsPerSecond = w / s.windowDuration;
    final double timeOffset = (ctx.t * pixelsPerSecond) % (w / vLines);
    
    for (int i = 0; i <= vLines + 1; i++) {
      final double x = w - ((w / vLines) * i) + timeOffset;
      if (x >= 0 && x <= w) {
        // Draw tick marks at the top and bottom
        canvas.drawLine(ui.Offset(x, 0), ui.Offset(x, 15), gridPaint);
        canvas.drawLine(ui.Offset(x, h), ui.Offset(x, h - 15), gridPaint);
      }
    }

    // --- 2. CALCULATE TIME WINDOW (Looking Backwards) ---
    // For a telemetry look, current time is on the RIGHT. 
    // We look backward into the past by windowDuration.
    int endIdx = ctx.sampleIndexAt(ctx.t);
    int startIdx = ctx.sampleIndexAt(ctx.t - s.windowDuration);
    if (startIdx < 0) startIdx = 0;
    
    final int chunkLen = endIdx - startIdx;
    if (chunkLen < 4) return;

    final double midY = h / 2.0;
    final double stepX = w / (chunkLen > 0 ? chunkLen : 1);
    final double gain = ctx.dampening * 1.5; // Fixed gain for predictability

    final ui.Path wavePath = ui.Path();
    final ui.Path envelopePath = ui.Path();

    envelopePath.moveTo(0, midY);

    // Build the paths moving left to right
    for (int i = 0; i < chunkLen; i++) {
      final int idx = startIdx + i;
      double v = idx < ctx.audio.length ? ctx.audio[idx] : 0.0;
      if (v.isNaN || v.isInfinite) v = 0.0;
      
      final double amplitude = (v * gain).clamp(-1.0, 1.0);
      final double y = midY - (amplitude * (h * 0.45));
      final double x = i * stepX;

      // Raw Waveform
      if (i == 0) {
        wavePath.moveTo(x, y);
      } else {
        wavePath.lineTo(x, y);
      }

      // Smooth Envelope (absolute amplitude)
      final double envY = midY - (amplitude.abs() * (h * 0.45));
      envelopePath.lineTo(x, envY);
    }
    
    // Close the envelope path to make a filled shape on the top half
    envelopePath.lineTo(w, midY);
    envelopePath.close();

    // --- 3. DRAW ENVELOPE (Soft fill for volume footprint) ---
    final ui.Paint envelopePaint = ui.Paint()
      ..style = ui.PaintingStyle.fill
      ..color = s.outerColor.withOpacity(0.2);
    canvas.drawPath(envelopePath, envelopePaint);

    // Mirror envelope for the bottom half
    canvas.save();
    canvas.translate(0, h);
    canvas.scale(1.0, -1.0);
    canvas.drawPath(envelopePath, envelopePaint);
    canvas.restore();

    // --- 4. DRAW CRISP WAVEFORM (Forensic trace) ---
    final ui.Paint wavePaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = (1.5 * s.strokeScale).clamp(1.0, 4.0)
      ..strokeJoin = ui.StrokeJoin.round
      ..color = s.midColor;

    if (s.glowBlurSigma > 0.0) {
      wavePaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
    }
    canvas.drawPath(wavePath, wavePaint);

    // Draw the bright core line on top
    final ui.Paint corePaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = s.coreColor;
    canvas.drawPath(wavePath, corePaint);

    // --- 5. DRAW PLAYHEAD (Current Time Indicator) ---
    // A glowing vertical bar on the extreme right
    final ui.Paint playheadPaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = s.coreColor.withOpacity(0.5 + (_smoothMid * 0.5)); // Pulses with voice
    if (s.glowBlurSigma > 0.0) {
      playheadPaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma * 2);
    }
    
    canvas.drawLine(ui.Offset(w - 2, 0), ui.Offset(w - 2, h), playheadPaint);
    
    // Playhead crisp core
    canvas.drawLine(
      ui.Offset(w - 1, 0), 
      ui.Offset(w - 1, h), 
      ui.Paint()..color = const ui.Color(0xFFFFFFFF)..strokeWidth = 1.0
    );
  }
}