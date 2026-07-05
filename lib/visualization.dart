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

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'fft.dart';
import 'visualizations/bass_halo.dart';
import 'visualizations/circular_spectrum.dart';
import 'visualizations/dot_matrix.dart';
import 'visualizations/phosphor_waveform.dart';
import 'visualizations/ridge_plot.dart';
import 'visualizations/spectrogram.dart';
import 'visualizations/spectrum_bars.dart';
import 'visualizations/vocal_telemetry.dart';

/// User-adjustable style. Mutable; the settings dialog edits it in
/// place. Plugins interpret these however makes sense for them
/// (e.g. spectrum bars use the phosphor colors and stroke scale).
class WaveformSettings {
  /// Seconds of audio shown across the width of the scope.
  double windowDuration;

  /// Fraction of the trail retained each frame (0 = no trail).
  double trailRetention;

  /// Gaussian blur sigma on the outer stroke (0 = hard look).
  double glowBlurSigma;

  /// Multiplier on stroke widths / bar weights.
  double strokeScale;

  Color outerColor;
  Color midColor;
  Color coreColor;
  
  /// The color composited behind the visualization in live preview
  /// and solid-background exports. Does not affect transparent exports.
  Color backgroundColor;

  WaveformSettings({
    this.windowDuration = 0.08,
    this.trailRetention = 215.0 / 255.0,
    this.glowBlurSigma = 2.0,
    this.strokeScale = 1.0,
    this.outerColor = const Color(0xFF1EA01E),
    this.midColor = const Color(0xFF32FF32),
    this.coreColor = const Color(0xFFC8FFC8),
    this.backgroundColor = const Color(0xFF000000),
  });

  factory WaveformSettings.defaults() => WaveformSettings();

  void resetToDefaults() {
    final WaveformSettings d = WaveformSettings.defaults();
    windowDuration = d.windowDuration;
    trailRetention = d.trailRetention;
    glowBlurSigma = d.glowBlurSigma;
    strokeScale = d.strokeScale;
    outerColor = d.outerColor;
    midColor = d.midColor;
    coreColor = d.coreColor;
    backgroundColor = d.backgroundColor;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'window_duration_sec': windowDuration,
        'trail_retention': trailRetention,
        'glow_blur_sigma': glowBlurSigma,
        'stroke_scale': strokeScale,
        'outer_color': _hex(outerColor),
        'mid_color': _hex(midColor),
        'core_color': _hex(coreColor),
        'background_color': _hex(backgroundColor),
      };

  static String _hex(Color c) =>
      '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// Fixed constants shared by multiple visualizations.
class WaveformStyle {
  static const double peakFloor = 0.005;
  static const double agcSmoothing = 0.9; // old-peak retention
  static const double gainMin = 0.5;
  static const double gainMax = 4.0;
  static const double edgeMargin = 10.0;  // px clamp top/bottom

  // Base stroke widths, multiplied by settings.strokeScale.
  static const double outerWidth = 5.0;
  static const double midWidth = 3.0;
  static const double coreWidth = 1.0;
}

/// Per-frame data handed to a Visualization. Audio-analysis products
/// (spectrum, band energies) are computed lazily and cached, so
/// plugins that don't use the FFT pay nothing for it.
class VizContext {
  static const int fftSize = 2048;

  final Float32List audio;
  final int sampleRate;
  final double t;           // seconds
  final int frameIndex;
  final double dt;          // seconds since previous frame
  final int width;
  final int height;
  final double dampening;
  final WaveformSettings settings;

  VizContext({
    required this.audio,
    required this.sampleRate,
    required this.t,
    required this.frameIndex,
    required this.dt,
    required this.width,
    required this.height,
    required this.dampening,
    required this.settings,
  });

  int get totalSamples => audio.length;

  /// Sample index for time [at], clamped to the buffer.
  int sampleIndexAt(double at) =>
      (at * sampleRate).toInt().clamp(0, audio.length);

  Float32List? _spectrum;

  /// Magnitude spectrum (fftSize/2 bins) of fftSize samples starting
  /// at the current time. Lazy; computed at most once per frame.
  Float32List get spectrum {
    _spectrum ??=
        Fft.magnitudeSpectrum(audio, sampleIndexAt(t), fftSize);
    return _spectrum!;
  }

  double? _bass, _mid, _treb;

  double get bass => _bass ??=
      Fft.bandEnergy(spectrum, fftSize, sampleRate, 20, 250);
  double get midBand => _mid ??=
      Fft.bandEnergy(spectrum, fftSize, sampleRate, 250, 2000);
  double get treb => _treb ??=
      Fft.bandEnergy(spectrum, fftSize, sampleRate, 2000, 16000);
}

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
///    blitting it on the current vsync. At display rate the GC keeps
///    up fine; this was never the leaking path.
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

    final double retention = ctx.settings.trailRetention.clamp(0.0, 0.995);
    if (_frame != null && retention > 0.0) {
      final Paint decayPaint = Paint()
        ..color = const Color(0xFFFFFFFF).withOpacity(retention);
      canvas.drawImage(_frame!, Offset.zero, decayPaint);
    }

    viz.render(canvas, ctx);
    return recorder.endRecording();
  }

  /// Live path. Synchronous to match monitor vsync. Frames are
  /// GC-owned: never disposed here, the painter may hold the old one.
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
      CircularSpectrum(),
      RidgePlotSpectrum(),
      DotMatrixSpectrum(),
      BassHalo(),
      VocalTelemetry(),
      VoiceprintSpectrogram(),
    ];