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
import 'visualizations/spectrum_bars.dart';

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

  WaveformSettings({
    this.windowDuration = 0.08,
    this.trailRetention = 215.0 / 255.0,
    this.glowBlurSigma = 2.0,
    this.strokeScale = 1.0,
    this.outerColor = const Color(0xFF1EA01E),
    this.midColor = const Color(0xFF32FF32),
    this.coreColor = const Color(0xFFC8FFC8),
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
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'window_duration_sec': windowDuration,
        'trail_retention': trailRetention,
        'glow_blur_sigma': glowBlurSigma,
        'stroke_scale': strokeScale,
        'outer_color': _hex(outerColor),
        'mid_color': _hex(midColor),
        'core_color': _hex(coreColor),
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
/// RGBA image suitable for live blit and PNG export alike.
class VizCompositor {
  final int width;
  final int height;

  ui.Image? _frame;

  VizCompositor({required this.width, required this.height});

  ui.Image? get image => _frame;

  void clear() {
    // Safe clear. Lets the GC sweep memory.
    _frame = null;
  }

  ui.Picture _record(Visualization viz, VizContext ctx, bool isExport) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    // VRAM LEAK FIX: Skip drawing the heavy texture trail if we are exporting.
    // This prevents Flutter from building an infinitely deep "Russian Doll" DisplayList.
    if (!isExport) {
      final double retention = ctx.settings.trailRetention.clamp(0.0, 0.995);
      if (_frame != null && retention > 0.0) {
        final Paint decayPaint = Paint()
          ..color = const Color(0xFFFFFFFF).withOpacity(retention);
        canvas.drawImage(_frame!, Offset.zero, decayPaint);
      }
    }

    viz.render(canvas, ctx);
    return recorder.endRecording();
  }

  /// Used by the live UI ticker. Runs synchronously to match monitor vsync.
  ui.Image advance(Visualization viz, VizContext ctx, {bool isExport = false}) {
    final ui.Picture picture = _record(viz, ctx, isExport);
    final ui.Image next = picture.toImageSync(width, height);
    picture.dispose();

    if (!isExport) {
      _frame = next;
    }
    
    return next;
  }

  /// Used by the offline exporter. Uses async rasterization to force the Flutter
  /// engine to flatten the display list into a real GPU texture, preventing
  /// catastrophic VRAM leaks from deeply nested Picture records.
  Future<ui.Image> advanceAsync(Visualization viz, VizContext ctx, {bool isExport = false}) async {
    final ui.Picture picture = _record(viz, ctx, isExport);
    
    // Await forces actual GPU rasterization, breaking the DisplayList chain.
    final ui.Image next = await picture.toImage(width, height);
    picture.dispose();

    if (!isExport) {
      _frame = next;
    }
    
    return next.clone();
  }

  void dispose() {
    // NEVER explicitly dispose _frame here! 
    // The live UI might still be trying to paint it on the current vsync.
    // Dart's Garbage Collector handles live UI frames safely and automatically.
    _frame = null;
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
    ];