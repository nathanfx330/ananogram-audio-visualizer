// ./lib/soft_visualizations.dart
//
// Tier 1 of the CPU render path: the SoftVisualization interface
// (Visualization's mirror against SoftCanvas instead of ui.Canvas)
// and the registry mapping plugin names to soft implementations.
//
// CONTRACT: a soft implementation must reproduce its GPU twin's
// output to visual indistinguishability -- same AGC math, same path
// geometry, same stroke stack, same state evolution. The determinism
// contract carries over unchanged: reset() followed by render()
// calls at a fixed sequence of times always produces identical
// bytes. That is what makes Phase 2's chunked fan-out correct: any
// worker can reset() and replay to its chunk start and land in
// exactly the state a straight-through render would have.
//
// SUPPRESSED REPLAY (renderSuppressed): the parallel pool rebuilds a
// worker's plugin state by replaying frames [0, chunkStart) WITHOUT
// stamping pixels. renderSuppressed must advance internal state
// through the EXACT arithmetic render() uses -- same sampling, same
// NaN handling, same recurrence, same early-return guards -- so the
// state entering a chunk is bit-identical to a serial bake's. Where
// render() does its stateful work in a first analysis pass (peak
// scan + AGC) and its stateless work in a second (path build +
// stroke), renderSuppressed runs the first and skips the second. Both
// call the SAME private state-update method so they cannot drift; a
// divergence would surface as a brightness/gain seam at chunk
// boundaries.
//
// The trail is NOT rendered here -- the export loop applies
// SoftCanvas.decay(retention) before each render call, mirroring
// VizCompositor._record's decay-then-draw order.
//
// VizContext is reused as-is: it is pure typed-data + lazy FFT, and
// WaveformSettings' Color fields are plain value objects -- all of
// it safe on a worker isolate.
//
// REGISTRY: softVisualizationFor(name) returns a FRESH instance per
// call (workers must not share plugin state across isolates), or
// null if the plugin is unported -- the exporter falls back to the
// GPU path for those, so nothing breaks while the port is partial.

import 'dart:math' as math;
import 'dart:typed_data';

import 'soft_raster.dart';
import 'viz_state.dart';

/// CPU-path plugin interface. Mirrors Visualization exactly, against
/// SoftCanvas. Same statefulness rules, same determinism contract.
abstract class SoftVisualization {
  /// Must match the GPU twin's Visualization.name -- it is the
  /// registry key and appears unchanged in the export manifest.
  String get name;

  /// Clears all internal state. Called at bake start and on every
  /// worker replay.
  void reset();

  /// Draws one frame onto [canvas]. The canvas arrives pre-decayed
  /// (trail already applied); draw on top, exactly like the GPU
  /// render(Canvas, ctx) does above the compositor's decay draw.
  void render(SoftCanvas canvas, VizContext ctx);

  /// Advances internal per-frame state for frame [ctx] WITHOUT
  /// drawing. Used by the parallel pool to replay [0, chunkStart) and
  /// rebuild state at a chunk boundary. Must evolve state identically
  /// to render() -- same analysis, same recurrence, same guards --
  /// but touch no canvas. For a stateless plugin this is a no-op; for
  /// a stateful one it runs exactly the state-updating portion of
  /// render().
  void renderSuppressed(VizContext ctx);
}

/// Returns a fresh soft implementation for the named plugin, or null
/// if it has no CPU port yet (exporter falls back to GPU).
SoftVisualization? softVisualizationFor(String name) {
  switch (name) {
    case 'Phosphor Waveform':
      return SoftPhosphorWaveform();
    case 'Spectrum Bars':
      return SoftSpectrumBars();
    case 'Line Spectrum':
      return SoftLineSpectrum();
    case 'Dot Matrix':
      return SoftDotMatrixSpectrum();
    case 'Circular Spectrum':
      return SoftCircularSpectrum();
    case 'Minimalist Halo':
      return SoftBassHalo();
    case 'Ridge Plot (Waterfall)':
      return SoftRidgePlotSpectrum();
    case 'Voiceprint Spectrogram':
      return SoftVoiceprintSpectrogram();
    default:
      return null;
  }
}

/// CPU twin of PhosphorWaveform: AGC'd time-domain waveform with
/// triple-stroke phosphor glow. The AGC math, sampling, and path
/// construction are copied line-for-line from the GPU version --
/// the only translation is ui.Path/Paint -> packed points +
/// strokePolyline calls.
class SoftPhosphorWaveform implements SoftVisualization {
  double _peakSmoothed = 1.0;

  @override
  String get name => 'Phosphor Waveform';

  @override
  void reset() => _peakSmoothed = 1.0;

  /// Stateful analysis pass: computes the window peak and advances the
  /// AGC recurrence, returning the frame's gain -- or null if this
  /// frame is guarded out (too short a window / too narrow a view),
  /// in which case state is left UNCHANGED, exactly as a serial
  /// render leaves it. render() and renderSuppressed() both funnel
  /// through here so state evolution is identical between a real bake
  /// and a replayed one. Returns (start, step, gain) so render() can
  /// reuse the sampling geometry without recomputing it.
  ({int start, double step, double gain})? _advance(VizContext ctx) {
    final int width = ctx.width;
    final double height = ctx.height.toDouble();

    final int start = ctx.sampleIndexAt(ctx.t);
    final int end = ctx.sampleIndexAt(ctx.t + ctx.settings.windowDuration);

    final int chunkLen = end - start;
    if (chunkLen < 4 || width < 2) return null;

    final double step = (chunkLen - 1) / (width - 1);

    // Peak of the resampled window.
    double currentPeak = 0.0;
    for (int x = 0; x < width; x++) {
      final int idx = start + (x * step).toInt();
      double v = ctx.audio[idx];
      if (v.isNaN || v.isInfinite) v = 0.0;
      final double a = v.abs();
      if (a > currentPeak) currentPeak = a;
    }
    currentPeak += 1e-8;

    final double tSm = math.pow(WaveformStyle.agcSmoothing, 30.0 * ctx.dt).toDouble();
    _peakSmoothed = _peakSmoothed * tSm + currentPeak * (1.0 - tSm);
    
    if (_peakSmoothed < WaveformStyle.peakFloor) {
      _peakSmoothed = WaveformStyle.peakFloor;
    }

    final double gain = (1.0 / _peakSmoothed)
            .clamp(WaveformStyle.gainMin, WaveformStyle.gainMax) *
        ctx.dampening;

    return (start: start, step: step, gain: gain);
  }

  @override
  void renderSuppressed(VizContext ctx) {
    // State-only: advance the AGC, discard the geometry. Identical
    // recurrence to render(), no stamping.
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    final ({int start, double step, double gain})? a = _advance(ctx);
    if (a == null) return; // same guard as _advance / the GPU version

    final int width = ctx.width;
    final double height = ctx.height.toDouble();
    final double mid = height / 2.0;
    final int start = a.start;
    final double step = a.step;
    final double gain = a.gain;

    // Second pass: packed polyline, one point per pixel column.
    final double yMin = WaveformStyle.edgeMargin;
    final double yMax = height - WaveformStyle.edgeMargin;

    final Float32List xy = Float32List(width * 2);
    for (int x = 0; x < width; x++) {
      final int idx = start + (x * step).toInt();
      double v = ctx.audio[idx];
      if (v.isNaN || v.isInfinite) v = 0.0;
      v = v.clamp(-1.0, 1.0);
      final double y = (mid - v * mid * gain).clamp(yMin, yMax);
      final int j = x << 1;
      xy[j] = x.toDouble();
      xy[j + 1] = y;
    }

    _strokeGlow(canvas, xy, ctx.settings);
  }

  static void _strokeGlow(
      SoftCanvas canvas, Float32List xy, WaveformSettings s) {
    final double scale = s.strokeScale;

    canvas.strokePolyline(
      xy,
      WaveformStyle.outerWidth * scale,
      s.outerColor,
      blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0,
    );
    canvas.strokePolyline(
      xy,
      WaveformStyle.midWidth * scale,
      s.midColor,
    );
    canvas.strokePolyline(
      xy,
      WaveformStyle.coreWidth * scale,
      s.coreColor,
    );
  }
}

/// CPU twin of SpectrumBars: log-spaced frequency bars with exponential smoothing.
class SoftSpectrumBars implements SoftVisualization {
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

  /// Stateful analysis pass: computes log-spaced FFT bins and advances the
  /// exponential smoothing recurrence. Does not touch the SoftCanvas.
  void _advance(VizContext ctx) {
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    final double logLo = math.log(loHz);
    final double logHi = math.log(hiHz);
    
    final double tSm = math.pow(smoothing, 30.0 * ctx.dt).toDouble();

    for (int b = 0; b < barCount; b++) {
      // Log-spaced band edges for this bar.
      final double f0 = math.exp(logLo + (logHi - logLo) * b / barCount);
      final double f1 = math.exp(logLo + (logHi - logLo) * (b + 1) / barCount);
      int k0 = (f0 / binHz).floor().clamp(0, spec.length - 1);
      int k1 = (f1 / binHz).ceil().clamp(k0 + 1, spec.length);

      double peak = 0.0;
      for (int k = k0; k < k1; k++) {
        if (spec[k] > peak) peak = spec[k];
      }

      // Perceptual-ish curve + user dampening.
      double level = (math.pow(peak, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);

      _levels[b] = _levels[b] * tSm + level * (1.0 - tSm);
    }
  }

  @override
  void renderSuppressed(VizContext ctx) {
    // State-only: advance the FFT sampling and smoothing, discard the geometry.
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;
    
    final double gap = 2.0;
    final double barW = (w - gap * (barCount - 1)) / barCount;
    final double maxBarH = h - 2 * WaveformStyle.edgeMargin;
    final double capH = (WaveformStyle.midWidth * s.strokeScale).clamp(1.0, 12.0);

    for (int b = 0; b < barCount; b++) {
      final double barH = _levels[b] * maxBarH;
      if (barH < 0.5) continue;

      final double x = b * (barW + gap);
      final double top = h - WaveformStyle.edgeMargin - barH;

      // Draw the glowing body
      canvas.fillRect(
        x, top, barW, barH, 
        s.midColor, 
        blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0,
      );
      
      // Draw the bright cap
      canvas.fillRect(
        x, top, barW, capH, 
        s.coreColor
      );
    }
  }
}

/// CPU twin of LineSpectrum: smooth flowing frequency curve
class SoftLineSpectrum implements SoftVisualization {
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

  void _advance(VizContext ctx) {
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    final double logLo = math.log(loHz);
    final double logHi = math.log(hiHz);
    
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
  }

  @override
  void renderSuppressed(VizContext ctx) {
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;
    
    final double maxH = h - (WaveformStyle.edgeMargin * 2);
    final double stepX = w / (pointCount - 1);

    final Float32List xy = Float32List(pointCount * 2);
    
    for (int p = 0; p < pointCount; p++) {
      final double x = p * stepX;
      final double y = h - WaveformStyle.edgeMargin - (_levels[p] * maxH);

      final int j = p << 1;
      xy[j] = x;
      xy[j + 1] = y;
    }

    final double scale = s.strokeScale;

    canvas.strokePolyline(
      xy,
      WaveformStyle.outerWidth * scale,
      s.outerColor,
      blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0,
    );
    canvas.strokePolyline(
      xy,
      WaveformStyle.midWidth * scale,
      s.midColor,
    );
    canvas.strokePolyline(
      xy,
      WaveformStyle.coreWidth * scale,
      s.coreColor,
    );
  }
}

/// CPU twin of DotMatrixSpectrum: LED/VFD style dot matrix equalizer.
class SoftDotMatrixSpectrum implements SoftVisualization {
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

  void _advance(VizContext ctx) {
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    final double logLo = math.log(20.0);
    final double logHi = math.log(16000.0);
    
    final double tSm = math.pow(smoothing, 30.0 * ctx.dt).toDouble();

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
    }
  }

  @override
  void renderSuppressed(VizContext ctx) {
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;

    // Calculate grid spacing
    final double dotSize = (w / columns) * 0.6;
    final double xGap = (w - (dotSize * columns)) / (columns + 1);
    final double yGap = (h - (dotSize * rows)) / (rows + 1);

    // Calculate the 15% opacity inactive color (0.15 * 255 = 38)
    final int inactiveAlpha = 38;
    final int inactiveColor = (s.outerColor & 0x00FFFFFF) | (inactiveAlpha << 24);

    for (int c = 0; c < columns; c++) {
      final int litRows = (_levels[c] * rows).round();
      final double x = xGap + c * (dotSize + xGap);

      for (int r = 0; r < rows; r++) {
        // Draw from bottom to top
        final double y = h - (yGap + r * (dotSize + yGap)) - dotSize;
        
        // If the row index is less than litRows, turn the LED "on"
        if (r < litRows) {
          canvas.drawOval(
            x, y, dotSize, dotSize, 
            s.coreColor,
            blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0,
          );
        } else {
          canvas.drawOval(
            x, y, dotSize, dotSize, 
            inactiveColor,
          );
        }
      }
    }
  }
}

/// CPU twin of CircularSpectrum: a radial frequency spectrum.
class SoftCircularSpectrum implements SoftVisualization {
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

  void _advance(VizContext ctx) {
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    final double logLo = math.log(20.0);
    final double logHi = math.log(16000.0);
    
    final double tSm = math.pow(smoothing, 30.0 * ctx.dt).toDouble();

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
      _levels[b] = _levels[b] * tSm + level * (1.0 - tSm);
    }
  }

  @override
  void renderSuppressed(VizContext ctx) {
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final double maxRadius = math.min(w, h) / 2.0 * 0.9; 
    final double baseRadius = maxRadius * minRadiusRatio;
    final WaveformSettings s = ctx.settings;

    final double strokeWidth = (2.0 * s.strokeScale).clamp(1.0, 10.0);
    final double blur = s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0;
    
    final double cx = w / 2;
    final double cy = h / 2;

    for (int b = 0; b < barCount; b++) {
      final double barLength = _levels[b] * (maxRadius - baseRadius);
      if (barLength < 1.0) continue;

      // Calculate angle (top center, moving clockwise)
      final double angle = (b / barCount) * 2 * math.pi - (math.pi / 2);
      
      final double cosA = math.cos(angle);
      final double sinA = math.sin(angle);

      final double startX = cx + (cosA * baseRadius);
      final double startY = cy + (sinA * baseRadius);
      final double endX = cx + (cosA * (baseRadius + barLength));
      final double endY = cy + (sinA * (baseRadius + barLength));

      // Pack coordinates into a Float32List for the SoftCanvas polyline API
      final Float32List xy = Float32List(4);
      xy[0] = startX;
      xy[1] = startY;
      xy[2] = endX;
      xy[3] = endY;

      canvas.strokePolyline(
        xy, 
        strokeWidth, 
        s.midColor,
        blurSigma: blur,
      );
    }
  }
}

/// CPU twin of BassHalo: Minimalist circular waveform.
class SoftBassHalo implements SoftVisualization {
  double _smoothBass = 0.0;

  @override
  String get name => 'Minimalist Halo';

  @override
  void reset() {
    _smoothBass = 0.0;
  }

  void _advance(VizContext ctx) {
    final double tSm = math.pow(0.8, 30.0 * ctx.dt).toDouble();
    _smoothBass = _smoothBass * tSm + (ctx.bass * 2.0) * (1.0 - tSm);
    _smoothBass = _smoothBass.clamp(0.0, 1.0);
  }

  @override
  void renderSuppressed(VizContext ctx) {
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;

    // Base radius scales with bass
    final double minRadius = math.min(w, h) * 0.25;
    final double maxRadius = math.min(w, h) * 0.40;
    final double currentRadius = minRadius + (_smoothBass * (maxRadius - minRadius));

    // Get waveform chunk
    int start = ctx.sampleIndexAt(ctx.t);
    int end = ctx.sampleIndexAt(ctx.t + s.windowDuration);
    final int chunkLen = end - start;
    if (chunkLen < 4) return;

    final int points = 360; 
    final double step = chunkLen / points;
    final double rippleScale = (maxRadius * 0.2) * ctx.dampening;

    // We only need the (x,y) points, so allocate length = points * 2
    final Float32List xy = Float32List(points * 2);

    for (int i = 0; i < points; i++) {
      final int idx = start + (i * step).toInt().clamp(0, chunkLen - 1);
      final double window = math.sin((i / points) * math.pi);
      
      double v = idx < ctx.audio.length ? ctx.audio[idx] : 0.0;
      if (v.isNaN || v.isInfinite) v = 0.0;
      v = v.clamp(-1.0, 1.0) * window;

      final double angle = (i / points) * 2 * math.pi - (math.pi / 2);
      final double r = currentRadius + (v * rippleScale);

      final int j = i << 1;
      xy[j] = (w / 2) + math.cos(angle) * r;
      xy[j + 1] = (h / 2) + math.sin(angle) * r;
    }

    // Outer Glow
    canvas.strokePolyline(
      xy, 
      6.0 * s.strokeScale, 
      s.outerColor,
      blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma * 2 : 0.0,
      close: true, // Mathematically seal the circle!
    );
    
    // Crisp Core
    canvas.strokePolyline(
      xy, 
      2.0 * s.strokeScale, 
      s.coreColor,
      close: true, 
    );
  }
}

/// CPU twin of RidgePlotSpectrum: A pseudo-3D scrolling waterfall plot.
class SoftRidgePlotSpectrum implements SoftVisualization {
  static const double historyDurationSec = 1.333;
  static const int points = 64;
  final List<List<double>> _history = [];

  @override
  String get name => 'Ridge Plot (Waterfall)';

  @override
  void reset() {
    _history.clear();
  }

  void _advance(VizContext ctx) {
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

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

    _history.insert(0, currentLine);
    
    final int historySize = (historyDurationSec / ctx.dt).round().clamp(10, 240);
    while (_history.length > historySize) {
      _history.removeLast();
    }
  }

  @override
  void renderSuppressed(VizContext ctx) {
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;
    
    final int historySize = (historyDurationSec / ctx.dt).round().clamp(10, 240);
    final double lineSpacing = h / (historySize + 10);
    final double maxSpike = lineSpacing * 8.0;

    // Draw from back to front to get proper occlusion (3D effect)
    for (int i = _history.length - 1; i >= 0; i--) {
      final List<double> lineData = _history[i];
      
      final double yBase = h - (i * lineSpacing) - WaveformStyle.edgeMargin;
      final double xOffset = i * (w * 0.005 * (40.0 / historySize)); 
      final double rowWidth = w - (historySize * w * 0.005 * (40.0 / historySize));
      final double step = rowWidth / (points - 1);

      // Create an opaque rect beneath the line to hide the lines behind it!
      // This replicates the `fillPath` occlusion trick from the GPU version.
      canvas.fillRect(
        xOffset, 
        yBase - maxSpike, 
        rowWidth, 
        maxSpike + lineSpacing, 
        s.backgroundColor
      );

      // Pack the line into a Float32List
      final Float32List xy = Float32List(points * 2);
      for (int p = 0; p < points; p++) {
        final double x = xOffset + (p * step);
        final double edgeFade = math.sin((p / (points - 1)) * math.pi);
        final double y = yBase - (lineData[p] * maxSpike * edgeFade);
        
        final int j = p << 1;
        xy[j] = x;
        xy[j + 1] = y;
      }

      canvas.strokePolyline(
        xy, 
        (1.5 * s.strokeScale).clamp(1.0, 5.0), 
        s.midColor
      );
    }
  }
}

/// CPU twin of VoiceprintSpectrogram: A 2D heatmap mapping frequency over time.
class SoftVoiceprintSpectrogram implements SoftVisualization {
  static const double historyDurationSec = 4.0;
  static const int freqRows = 64;     // Y-axis resolution (frequencies)
  
  final List<List<double>> _history = [];

  @override
  String get name => 'Voiceprint Spectrogram';

  @override
  void reset() {
    _history.clear();
  }

  void _advance(VizContext ctx) {
    final Float32List spec = ctx.spectrum;
    final double binHz = ctx.sampleRate / VizContext.fftSize;

    List<double> currentColumn = List.filled(freqRows, 0.0);
    
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
      
      currentColumn[r] = (math.pow(peak, 0.5).toDouble() * ctx.dampening).clamp(0.0, 1.0);
    }

    _history.insert(0, currentColumn);
    
    final int timeColumns = (historyDurationSec / ctx.dt).round().clamp(10, 500);
    while (_history.length > timeColumns) {
      _history.removeLast();
    }
  }

  @override
  void renderSuppressed(VizContext ctx) {
    _advance(ctx);
  }

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    _advance(ctx);

    final double w = ctx.width.toDouble();
    final double h = ctx.height.toDouble();
    final WaveformSettings s = ctx.settings;
    
    final int timeColumns = (historyDurationSec / ctx.dt).round().clamp(10, 500);
    final double cellW = w / timeColumns;
    final double cellH = h / freqRows;
    
    final double padX = cellW > 2.0 ? 1.0 : 0.0;
    final double padY = cellH > 2.0 ? 1.0 : 0.0;

    final double normalizedRetention = (s.trailRetention / 0.95).clamp(0.01, 1.0);
    final double maxVisibleCols = timeColumns * normalizedRetention;

    for (int col = 0; col < _history.length; col++) {
      final List<double> columnData = _history[col];
      
      final double ageFactor = 1.0 - (col / maxVisibleCols);
      if (ageFactor <= 0.0) continue; 

      final double x = w - ((col + 1) * cellW);

      for (int row = 0; row < freqRows; row++) {
        final double val = columnData[row];
        if (val < 0.02) continue;

        final double y = h - ((row + 1) * cellH);

        // Map intensity to pure integer ARGB color
        int baseColor = _mapValueToColor(val, s);
        
        // Calculate new alpha channel based on ageFactor
        int originalAlpha = (baseColor >> 24) & 0xFF;
        int newAlpha = (originalAlpha * ageFactor).clamp(0, 255).toInt();
        int finalColor = (baseColor & 0x00FFFFFF) | (newAlpha << 24);
        
        canvas.fillRect(
          x + padX, 
          y + padY, 
          cellW - padX, 
          cellH - padY, 
          finalColor,
          blurSigma: s.glowBlurSigma > 0.0 ? math.min(s.glowBlurSigma, cellW * 0.5) : 0.0
        );
      }
    }

    // DRAW PLAYHEAD
    final Float32List xy = Float32List(4);
    xy[0] = w - 1;
    xy[1] = 0;
    xy[2] = w - 1;
    xy[3] = h;

    int playheadAlpha = (255 * 0.8).toInt();
    int playheadColor = (s.coreColor & 0x00FFFFFF) | (playheadAlpha << 24);

    canvas.strokePolyline(
      xy, 
      2.0, 
      playheadColor,
      blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0
    );
  }

  /// Pure integer lerp function to replace dart:ui Color.lerp
  int _lerpColor(int a, int b, double t) {
    if (t <= 0.0) return a;
    if (t >= 1.0) return b;

    final int aa = (a >> 24) & 0xFF;
    final int ar = (a >> 16) & 0xFF;
    final int ag = (a >> 8) & 0xFF;
    final int ab = a & 0xFF;

    final int ba = (b >> 24) & 0xFF;
    final int br = (b >> 16) & 0xFF;
    final int bg = (b >> 8) & 0xFF;
    final int bb = b & 0xFF;

    final int ra = (aa + (ba - aa) * t).round();
    final int rr = (ar + (br - ar) * t).round();
    final int rg = (ag + (bg - ag) * t).round();
    final int rb = (ab + (bb - ab) * t).round();

    return (ra << 24) | (rr << 16) | (rg << 8) | rb;
  }

  int _mapValueToColor(double v, WaveformSettings s) {
    if (v < 0.33) {
      return _lerpColor(0x00000000, s.outerColor, v / 0.33);
    } else if (v < 0.66) {
      return _lerpColor(s.outerColor, s.midColor, (v - 0.33) / 0.33);
    } else {
      return _lerpColor(s.midColor, s.coreColor, (v - 0.66) / 0.34);
    }
  }
}