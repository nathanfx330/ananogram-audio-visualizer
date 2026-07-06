// ./lib/visualization.dart
//
// Tier 1 of the visualization platform: the plugin interface, the
// per-frame context handed to plugins, the frame compositor (trail
// decay + plugin render), user-adjustable style settings, and the
// registry of built-in visualizations.
//
// A Visualization is stateful (smoothing, AGC, etc.) but must be
// deterministic: reset() followed by render() calls at a fixed
// sequence of times must always produce identical output. That
// contract is what lets the exporter bake any plugin.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'viz_state.dart';
import 'visualizations/bass_halo.dart';
import 'visualizations/circular_spectrum.dart';
import 'visualizations/dot_matrix.dart';
import 'visualizations/line_spectrum.dart';
import 'visualizations/phosphor_waveform.dart';
import 'visualizations/ridge_plot.dart';
import 'visualizations/spectrogram.dart';
import 'visualizations/spectrum_bars.dart';
import 'visualizations/vocal_telemetry.dart';

export 'viz_state.dart';

/// Plugin interface. Implementations may hold internal state
/// (smoothing, AGC) but must honor the determinism contract described
/// at the top of this file.
abstract class Visualization {
  /// Display name for the UI and the export manifest.
  String get name;

  /// Clears all internal state. Called on audio load and at the start
  /// of every export bake.
  void reset();

  /// Draws one frame onto [canvas] (transparent background; the
  /// compositor has already applied trail decay beneath).
  void render(Canvas canvas, VizContext ctx);
}

/// Frame compositor: retains the previous frame as a GPU image,
/// decays it by settings.trailRetention, then lets the active
/// visualization draw on top. Output is a premultiplied transparent
/// RGBA image suitable for live blit and raw-pixel export alike.
///
/// FRAME OWNERSHIP MODEL (the VRAM fix):
///
/// The historical export leak (~6 GB/min) was never the trail draw
/// itself -- it was frame lifetime. Superseded ui.Images were left
/// to the GC, which does not feel GPU memory pressure, so textures
/// accumulated (~8 MB/frame at 1080p) far faster than any collection
/// reclaimed them. Skipping the trail during export didn't close the
/// leak either: advanceAsync still produced one unreferenced,
/// undisposed texture per frame.
///
/// Two paths, two ownership rules:
///
///  * Live (advance): frames are GC-owned. The previous frame is
///    NEVER explicitly disposed, because VizBlitPainter may be
///    blitting it on the current vsync -- and the UI can repaint a
///    cached frame at any time (e.g. on pointer hover), so there is
///    no vsync count after which an explicit dispose is provably
///    safe. Disposing here crashes the engine ("painting disposed
///    image"). Live VRAM is instead bounded by HALTING THE TICKER
///    when idle (see main.dart _onTick): the GC only needs an idle
///    gap to sweep the orphaned textures, and stopping advance()
///    calls gives it one. This is the sanctioned live-path model --
///    do not add explicit disposal here.
///
///  * Export (advanceAsync): frames are compositor-owned. The
///    superseded frame is disposed the instant the new one is
///    rasterized. Exactly two textures are ever alive (previous +
///    current), so memory stays flat regardless of duration -- and
///    the trail draws during export again, restoring the
///    preview/export parity the README promises.
///
/// advanceAsync awaits Picture.toImage, which forces real GPU
/// rasterization: the retained frame is a flat texture, never a
/// nested DisplayList, so the trail draw cannot recurse ("Russian
/// Doll" DisplayList problem).
class VizCompositor {
  final int width;
  final int height;

  ui.Image? _frame;
  bool _ownsFrame = false; // set by advanceAsync; guards explicit dispose

  VizCompositor({required this.width, required this.height});

  ui.Image? get image => _frame;

  void clear() {
    if (_ownsFrame) _frame?.dispose();
    _frame = null;
    _ownsFrame = false;
  }

  ui.Picture _record(Visualization viz, VizContext ctx) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    final double r30 = ctx.settings.trailRetention.clamp(0.0, 0.995);
    if (_frame != null && r30 > 0.0) {
      // Continuous-time decay: map the 30fps-tuned retention to actual time elapsed
      final double r = math.pow(r30, 30.0 * ctx.dt).toDouble();
      final Paint decayPaint = Paint()
        ..color = const Color(0xFFFFFFFF).withOpacity(r);
      canvas.drawImage(_frame!, Offset.zero, decayPaint);
    }

    viz.render(canvas, ctx);
    return recorder.endRecording();
  }

  /// Live path. Synchronous to match monitor vsync. Frames are
  /// GC-owned: never disposed here, the painter may hold the old one
  /// and the UI may repaint a cached frame on interaction. VRAM is
  /// bounded by the Ticker halting when idle (main.dart), not by
  /// disposal here.
  /// [isExport] is retained for call-site compatibility and ignored.
  ui.Image advance(Visualization viz, VizContext ctx,
      {bool isExport = false}) {
    final ui.Picture picture = _record(viz, ctx);
    final ui.Image next = picture.toImageSync(width, height);
    picture.dispose();

    _frame = next;
    _ownsFrame = false;
    return next;
  }

  /// Export path. Awaiting toImage forces GPU rasterization to a flat
  /// texture. The superseded frame is disposed immediately -- this is
  /// the VRAM fix. Returns a clone: the caller owns and disposes the
  /// clone, the compositor owns and disposes the retained frame.
  /// [isExport] is retained for call-site compatibility and ignored.
  Future<ui.Image> advanceAsync(Visualization viz, VizContext ctx,
      {bool isExport = false}) async {
    final ui.Picture picture = _record(viz, ctx);
    final ui.Image next = await picture.toImage(width, height);
    picture.dispose();

    final ui.Image? prev = _frame;
    _frame = next;
    if (_ownsFrame) prev?.dispose();
    _ownsFrame = true;

    return next.clone();
  }

  void dispose() {
    // Only dispose frames this compositor owns (export path). Live
    // frames stay GC-owned: the UI might still paint one this vsync.
    if (_ownsFrame) _frame?.dispose();
    _frame = null;
    _ownsFrame = false;
  }
}

/// Built-in visualization registry. Order is UI order.
List<Visualization> buildVisualizations() => <Visualization>[
      PhosphorWaveform(),
      SpectrumBars(),
      LineSpectrum(),
      CircularSpectrum(),
      RidgePlotSpectrum(),
      DotMatrixSpectrum(),
      BassHalo(),
      VocalTelemetry(),
      VoiceprintSpectrogram(),
    ];