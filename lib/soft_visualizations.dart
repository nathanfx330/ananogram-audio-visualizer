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

    _peakSmoothed = _peakSmoothed * WaveformStyle.agcSmoothing +
        currentPeak * (1.0 - WaveformStyle.agcSmoothing);
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

      _levels[b] = _levels[b] * smoothing + level * (1.0 - smoothing);
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