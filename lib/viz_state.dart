// ./lib/viz_state.dart
//
// Pure-Dart state structures for Ananogram.
//
// Extracted from visualization.dart to ensure background isolates (like
// the CPU render pool) never import dart:ui. Importing dart:ui on a
// background isolate forces Flutter to spin up a full Engine and GPU
// context, which leads to silent VRAM exhaustion.

import 'dart:typed_data';
import 'fft.dart';

/// User-adjustable style. Mutable; the settings dialog edits it in
/// place. Plugins interpret these however makes sense for them.
/// Uses raw ARGB ints instead of ui.Color to remain pure-Dart.
class WaveformSettings {
  /// Seconds of audio shown across the width of the scope.
  double windowDuration;

  /// Fraction of the trail retained each frame (0 = no trail).
  double trailRetention;

  /// Gaussian blur sigma on the outer stroke (0 = hard look).
  double glowBlurSigma;

  /// Multiplier on stroke widths / bar weights.
  double strokeScale;

  int outerColor;
  int midColor;
  int coreColor;
  
  /// The color composited behind the visualization in live preview
  /// and solid-background exports. Does not affect transparent exports.
  int backgroundColor;

  WaveformSettings({
    this.windowDuration = 0.08,
    this.trailRetention = 215.0 / 255.0,
    this.glowBlurSigma = 2.0,
    this.strokeScale = 1.0,
    this.outerColor = 0xFF1EA01E,
    this.midColor = 0xFF32FF32,
    this.coreColor = 0xFFC8FFC8,
    this.backgroundColor = 0xFF000000,
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

  static String _hex(int c) =>
      '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
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