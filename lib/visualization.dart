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
import 'visualizations/audio_meters.dart';
import 'visualizations/bass_halo.dart';
import 'visualizations/circular_spectrum.dart';
import 'visualizations/dot_matrix.dart';
import 'visualizations/horizontal_meters.dart';
import 'visualizations/line_spectrum.dart';
import 'visualizations/phosphor_waveform.dart';
import 'visualizations/ridge_plot.dart';
import 'visualizations/spectrogram.dart';
import 'visualizations/spectrum_bars.dart';
import 'visualizations/terminal_waves.dart';
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

/// A single recorded frame of vector geometry for the live preview trail.
class LiveFrame {
  final ui.Image image;
  final double t; // The absolute audio time this frame was recorded
  LiveFrame(this.image, this.t);
}

/// Frame compositor: retains the previous frame as a GPU image,
/// decays it by settings.trailRetention, then lets the active
/// visualization draw on top. Output is a premultiplied transparent
/// RGBA image suitable for live blit and raw-pixel export alike.
///
/// FRAME OWNERSHIP MODEL (the VRAM fix, v4 final):
///
///  * Export (advanceAsync): the superseded frame is disposed the
///    instant the new one is rasterized. Exactly two textures ever
///    alive (previous + current); memory flat regardless of duration.
///
///  * Live (advance): THE NON-RECURSIVE HISTORY RING.
///
///    THE "RUSSIAN DOLL" LEAK RESOLVED:
///    Previously, the live path fed the composited image back into itself
///    using `toImageSync`. Because `toImageSync` defers rasterization, this
///    created a recursively nested DisplayList that exploded VRAM usage.
///    To fix this while maintaining 60fps, we break the feedback loop. 
///    `advance` now records ONLY the current frame's vector art and pushes 
///    it to a short history list (`_liveHistory`). It then composites that 
///    list into a single flat UI frame. Nesting depth is strictly O(1), 
///    completely eliminating the leak.
class VizCompositor {
  final int width;
  final int height;

  ui.Image? _frame;
  bool _ownsFrame = false; // set by advanceAsync; guards export dispose

  // Live-path history ring. Holds individual flat frames for the trail.
  final List<LiveFrame> _liveHistory = [];
  static const int _maxLiveHistory = 45; // Hard cap on preview trail length (~1.5s)

  VizCompositor({required this.width, required this.height});

  ui.Image? get image => _frame;

  /// Resets the retained frame and clears the live history.
  void clear() {
    if (_ownsFrame) _frame?.dispose();
    for (final f in _liveHistory) {
      f.image.dispose();
    }
    _liveHistory.clear();
    _frame = null;
    _ownsFrame = false;
  }

  // --- EXPORT PATH (Accurate, flattened, async) ---
  ui.Picture _recordExport(Visualization viz, VizContext ctx) {
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

  Future<ui.Image> advanceAsync(Visualization viz, VizContext ctx,
      {bool isExport = false}) async {
    final ui.Picture picture = _recordExport(viz, ctx);
    final ui.Image next = await picture.toImage(width, height);
    picture.dispose();

    final ui.Image? prev = _frame;
    _frame = next;
    if (_ownsFrame) prev?.dispose();
    _ownsFrame = true;

    return next.clone();
  }

  // --- LIVE PATH (Non-recursive, lightning fast, leak-proof) ---
  ui.Image advance(Visualization viz, VizContext ctx, {bool isExport = false}) {
    // 0. Handle timeline scrubs (time goes backwards)
    if (_liveHistory.isNotEmpty && ctx.t < _liveHistory.last.t) {
      for (final f in _liveHistory) f.image.dispose();
      _liveHistory.clear();
    }

    // 1. Record ONLY this frame's vector art (no background, no previous frame)
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    viz.render(canvas, ctx);
    final ui.Picture pic = recorder.endRecording();
    
    // Rasterize synchronously. Because it contains NO nested images, this is O(1).
    final ui.Image img = pic.toImageSync(width, height);
    pic.dispose();

    _liveHistory.add(LiveFrame(img, ctx.t));

    // 2. Prune old history frames based on true opacity calculation
    final double r30 = ctx.settings.trailRetention.clamp(0.0, 0.995);
    _liveHistory.removeWhere((f) {
      final double age = ctx.t - f.t;
      final double opacity = math.pow(r30, 30.0 * age).toDouble();
      if (opacity < 0.01) { // Invisible
        f.image.dispose();
        return true;
      }
      return false;
    });

    // Hard cap to bound VRAM, preventing runaway on extreme retention sliders
    if (_liveHistory.length > _maxLiveHistory) {
      int excess = _liveHistory.length - _maxLiveHistory;
      for (int i = 0; i < excess; i++) {
        _liveHistory[i].image.dispose();
      }
      _liveHistory.removeRange(0, excess);
    }

    // 3. Composite the history into a single flat image for the UI to display
    final ui.PictureRecorder compRecorder = ui.PictureRecorder();
    final Canvas compCanvas = Canvas(
      compRecorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    for (final f in _liveHistory) {
      final double age = ctx.t - f.t;
      if (age < 0) continue;
      final double opacity = math.pow(r30, 30.0 * age).toDouble().clamp(0.0, 1.0);
      final Paint p = Paint()..color = Color.fromRGBO(255, 255, 255, opacity);
      compCanvas.drawImage(f.image, Offset.zero, p);
    }

    final ui.Picture compPic = compRecorder.endRecording();
    final ui.Image compImg = compPic.toImageSync(width, height);
    compPic.dispose();

    // 4. Update the compositor state safely
    if (_ownsFrame) _frame?.dispose();
    _frame = compImg;
    _ownsFrame = true;

    return compImg;
  }

  /// Full teardown.
  void dispose() {
    clear();
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
      TerminalWaves(),
      AudioMeters(),
      HorizontalMeters(),
    ];