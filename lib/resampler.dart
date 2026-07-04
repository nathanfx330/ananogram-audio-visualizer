// ./lib/resampler.dart
//
// Pure-Dart polyphase resampler, functional replacement for
// scipy.signal.resample_poly. Windowed-sinc (Hann) anti-aliasing
// filter, rational rate conversion via zero-stuffed polyphase
// evaluation. No dependencies outside dart core.

import 'dart:math' as math;
import 'dart:typed_data';

class Resampler {
  /// Resamples [input] from [fromRate] Hz to [toRate] Hz.
  ///
  /// Returns a new Float32List. If the rates are equal, returns the
  /// input unchanged (same instance - caller should not mutate).
  ///
  /// Filter design mirrors scipy.signal.resample_poly defaults in
  /// structure: cutoff at the tighter of the two Nyquist limits,
  /// 10 zero-crossings of sinc per side at the upsampled rate,
  /// linear-phase FIR, unity passband gain.
  static Float32List resample(Float32List input, int fromRate, int toRate) {
    if (fromRate <= 0 || toRate <= 0) {
      throw ArgumentError('Sample rates must be positive '
          '(got $fromRate -> $toRate).');
    }
    if (fromRate == toRate || input.isEmpty) {
      return input;
    }

    final int g = _gcd(fromRate, toRate);
    final int up = toRate ~/ g;
    final int down = fromRate ~/ g;

    final Float32List h = _designFilter(up, down);
    final int center = (h.length - 1) ~/ 2;

    final int outLength = ((input.length * up) + down - 1) ~/ down;
    final Float32List output = Float32List(outLength);

    final int inLength = input.length;
    final int tapCount = h.length;

    for (int n = 0; n < outLength; n++) {
      // Position of this output sample on the zero-stuffed
      // (upsampled-by-`up`) timeline, shifted so the filter is
      // centered (zero phase delay).
      final int m = n * down + center;

      // Contributing input samples j satisfy: 0 <= m - j*up < tapCount
      int jMin = (m - tapCount + up) ~/ up; // ceil((m - tapCount + 1) / up)
      if (m - tapCount + 1 > 0 && (m - tapCount + 1) % up != 0) {
        jMin = (m - tapCount + 1) ~/ up + 1;
      } else if (m - tapCount + 1 <= 0) {
        jMin = 0;
      } else {
        jMin = (m - tapCount + 1) ~/ up;
      }
      if (jMin < 0) jMin = 0;

      int jMax = m ~/ up;
      if (jMax > inLength - 1) jMax = inLength - 1;

      double acc = 0.0;
      for (int j = jMin; j <= jMax; j++) {
        acc += h[m - j * up] * input[j];
      }
      output[n] = acc;
    }

    return output;
  }

  /// Designs the anti-aliasing/anti-imaging lowpass FIR.
  ///
  /// Cutoff: 1/max(up, down) in normalized frequency at the upsampled
  /// rate (i.e. the tighter Nyquist limit of source and target).
  /// Length: 2 * (10 * max(up, down)) * ... capped -- see below.
  /// Window: Hann. Gain: `up` (compensates zero-stuffing energy loss).
  static Float32List _designFilter(int up, int down) {
    final int maxRate = math.max(up, down);

    // 10 sinc zero-crossings per side at the upsampled rate, but cap
    // total taps to keep pathological rate pairs (large coprime
    // up/down) from exploding. 8192-per-side is far beyond audible
    // transparency for audio work.
    int halfLen = 10 * maxRate;
    const int halfLenCap = 8192;
    if (halfLen > halfLenCap) halfLen = halfLenCap;

    final int tapCount = 2 * halfLen + 1;
    final Float32List h = Float32List(tapCount);

    final double fc = 1.0 / maxRate; // normalized cutoff (Nyquist = 1)

    for (int i = 0; i < tapCount; i++) {
      final int k = i - halfLen;

      // Sinc lowpass
      double v;
      if (k == 0) {
        v = fc;
      } else {
        final double x = math.pi * k;
        v = math.sin(fc * x) / x;
      }

      // Hann window
      final double w =
          0.5 - 0.5 * math.cos(2.0 * math.pi * i / (tapCount - 1));

      h[i] = (v * w * up).toDouble();
    }

    return h;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final int t = b;
      b = a % b;
      a = t;
    }
    return a;
  }
}