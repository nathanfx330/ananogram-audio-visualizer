// ./lib/fft.dart
//
// Pure-Dart radix-2 iterative Cooley-Tukey FFT plus audio helpers:
// Hann-windowed magnitude spectrum and frequency-band energy.
// No dependencies outside dart core.

import 'dart:math' as math;
import 'dart:typed_data';

class Fft {
  /// In-place complex FFT. [re] and [im] must have equal power-of-two
  /// length.
  static void transform(Float64List re, Float64List im) {
    final int n = re.length;
    if (n != im.length || (n & (n - 1)) != 0) {
      throw ArgumentError('FFT length must be a power of two.');
    }

    // Bit-reversal permutation
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j &= ~bit;
      }
      j |= bit;
      if (i < j) {
        final double tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final double ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    // Butterflies
    for (int len = 2; len <= n; len <<= 1) {
      final double ang = -2.0 * math.pi / len;
      final double wr = math.cos(ang);
      final double wi = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double curR = 1.0, curI = 0.0;
        final int half = len >> 1;
        for (int k = 0; k < half; k++) {
          final int a = i + k;
          final int b = a + half;
          final double tr = re[b] * curR - im[b] * curI;
          final double ti = re[b] * curI + im[b] * curR;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
          final double nr = curR * wr - curI * wi;
          curI = curR * wi + curI * wr;
          curR = nr;
        }
      }
    }
  }

  /// Hann-windowed magnitude spectrum of [size] samples of [audio]
  /// starting at [start]. Returns size/2 magnitudes, roughly
  /// normalized so a full-scale sine peaks near 1.0. Samples past the
  /// end of [audio] are zero-padded; negative [start] clamps to 0.
  static Float32List magnitudeSpectrum(
      Float32List audio, int start, int size) {
    if ((size & (size - 1)) != 0) {
      throw ArgumentError('FFT size must be a power of two.');
    }
    final Float64List re = Float64List(size);
    final Float64List im = Float64List(size);

    final int s = start < 0 ? 0 : start;
    final int n = audio.length;
    for (int i = 0; i < size; i++) {
      final int idx = s + i;
      final double v = idx < n ? audio[idx] : 0.0;
      // Hann window
      final double w =
          0.5 - 0.5 * math.cos(2.0 * math.pi * i / (size - 1));
      re[i] = v * w;
    }

    transform(re, im);

    final int half = size >> 1;
    final Float32List mags = Float32List(half);
    // Hann coherent gain is 0.5; single-sided amplitude needs x2.
    final double norm = 4.0 / size;
    for (int k = 0; k < half; k++) {
      final double m =
          math.sqrt(re[k] * re[k] + im[k] * im[k]) * norm;
      mags[k] = m > 1.0 ? 1.0 : m;
    }
    return mags;
  }

  /// Mean magnitude across [loHz, hiHz) in a spectrum produced by
  /// magnitudeSpectrum with the given [fftSize] and [sampleRate].
  static double bandEnergy(Float32List spectrum, int fftSize,
      int sampleRate, double loHz, double hiHz) {
    final double binHz = sampleRate / fftSize;
    int lo = (loHz / binHz).floor();
    int hi = (hiHz / binHz).ceil();
    lo = lo.clamp(0, spectrum.length - 1);
    hi = hi.clamp(lo + 1, spectrum.length);
    double acc = 0.0;
    for (int k = lo; k < hi; k++) {
      acc += spectrum[k];
    }
    return acc / (hi - lo);
  }
}