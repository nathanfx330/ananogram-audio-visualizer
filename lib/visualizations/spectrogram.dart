// ./lib/visualizations/spectrogram.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../visualization.dart';

/// A 2D heatmap/spectrogram plotting frequency over time.
/// Designed with a discrete, pixelated grid for a forensic/data aesthetic.
class VoiceprintSpectrogram implements Visualization {
  static const int timeColumns = 120; // X-axis resolution (history)
  static const int freqRows = 64;     // Y-axis resolution (frequencies)
  
  final List<List<double>> _history = [];

  @override
  String get name => 'Voiceprint Spectrogram';

  @override
  void reset() {
    _history.clear();
  }

  @override
  void render(ui.Canvas canvas, VizContext ctx) {
    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    // --- 1. PROCESS CURRENT FRAME ---
    List<double> currentColumn = List.filled(freqRows, 0.0);
    
    // Focus on the human hearing/speech range
    final double logLo = math.log(20.0);
    final double logHi = math.log(14000.0);

    for (int r = 0; r < freqRows; r++) {
      final double f0 = math.exp(logLo + (logHi - logLo) * r / freqRows);
      final double f1 = math.exp(logLo + (logHi - logLo) * (r + 1) / freqRows);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }
      
      // Scale and apply user dampening
      currentColumn[r] = (math.pow(peak, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);
    }

    // --- 2. UPDATE HISTORY ---
    _history.insert(0, currentColumn);
    if (_history.length > timeColumns) {
      _history.removeLast();
    }

    // --- 3. DRAW THE GRID ---
    final double cellW = w / timeColumns;
    final double cellH = h / freqRows;
    
    // Tiny gap creates the "pixelated data" look
    final double padX = cellW > 2.0 ? 1.0 : 0.0;
    final double padY = cellH > 2.0 ? 1.0 : 0.0;

    final ui.Paint cellPaint = ui.Paint()..style = ui.PaintingStyle.fill;
    
    // Apply Glow slider to the data blocks (capped so small cells don't vanish)
    if (s.glowBlurSigma > 0.0) {
      cellPaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, math.min(s.glowBlurSigma, cellW * 0.5));
    }

    // Map the trail slider to a physical distance across the screen (in columns).
    // Normalize against 0.95 so default settings stretch nicely across the view.
    final double normalizedRetention = (s.trailRetention / 0.95).clamp(0.01, 1.0);
    final double maxVisibleCols = timeColumns * normalizedRetention;

    for (int col = 0; col < _history.length; col++) {
      final List<double> columnData = _history[col];
      
      // Calculate age-based opacity (1.0 = newest, 0.0 = totally faded)
      final double ageFactor = 1.0 - (col / maxVisibleCols);
      if (ageFactor <= 0.0) continue; // Skip rendering if completely faded

      // Calculate X moving right-to-left
      final double x = w - ((col + 1) * cellW);

      for (int row = 0; row < freqRows; row++) {
        final double val = columnData[row];
        
        // Skip rendering if the cell is dead silent
        if (val < 0.02) continue;

        // Calculate Y moving bottom-to-top (low freqs at bottom)
        final double y = h - ((row + 1) * cellH);

        // Map intensity to color, then apply the age fade
        ui.Color baseColor = _mapValueToColor(val, s);
        cellPaint.color = baseColor.withOpacity((baseColor.opacity * ageFactor).clamp(0.0, 1.0));
        
        canvas.drawRect(
          ui.Rect.fromLTWH(x + padX, y + padY, cellW - padX, cellH - padY), 
          cellPaint
        );
      }
    }

    // --- 4. DRAW PLAYHEAD ---
    // A glowing vertical bar on the extreme right to anchor the data
    final ui.Paint playheadPaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = ui.Color(s.coreColor).withOpacity(0.8);
      
    if (s.glowBlurSigma > 0.0) {
      playheadPaint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, s.glowBlurSigma);
    }
    
    canvas.drawLine(ui.Offset(w - 1, 0), ui.Offset(w - 1, h), playheadPaint);
  }

  /// Helper: Maps a 0.0 - 1.0 float to the user's color palette.
  /// Transparent -> Outer Color -> Mid Color -> Core Color
  ui.Color _mapValueToColor(double v, WaveformSettings s) {
    if (v < 0.33) {
      return ui.Color.lerp(const ui.Color(0x00000000), ui.Color(s.outerColor), v / 0.33)!;
    } else if (v < 0.66) {
      return ui.Color.lerp(ui.Color(s.outerColor), ui.Color(s.midColor), (v - 0.33) / 0.33)!;
    } else {
      return ui.Color.lerp(ui.Color(s.midColor), ui.Color(s.coreColor), (v - 0.66) / 0.34)!;
    }
  }
}