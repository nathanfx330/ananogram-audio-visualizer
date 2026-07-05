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

import 'dart:typed_data';

import 'soft_raster.dart';
import 'visualization.dart';

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
}

/// Returns a fresh soft implementation for the named plugin, or null
/// if it has no CPU port yet (exporter falls back to GPU).
SoftVisualization? softVisualizationFor(String name) {
  switch (name) {
    case 'Phosphor Waveform':
      return SoftPhosphorWaveform();
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

  @override
  void render(SoftCanvas canvas, VizContext ctx) {
    final int width = ctx.width;
    final double height = ctx.height.toDouble();

    final int start = ctx.sampleIndexAt(ctx.t);
    final int end = ctx.sampleIndexAt(ctx.t + ctx.settings.windowDuration);

    final int chunkLen = end - start;
    if (chunkLen < 4 || width < 2) return;

    final double mid = height / 2.0;
    final double step = (chunkLen - 1) / (width - 1);

    // First pass: peak of the resampled window.
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
      s.outerColor.value,
      blurSigma: s.glowBlurSigma > 0.0 ? s.glowBlurSigma : 0.0,
    );
    canvas.strokePolyline(
      xy,
      WaveformStyle.midWidth * scale,
      s.midColor.value,
    );
    canvas.strokePolyline(
      xy,
      WaveformStyle.coreWidth * scale,
      s.coreColor.value,
    );
  }
}