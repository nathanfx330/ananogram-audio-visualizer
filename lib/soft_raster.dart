// ./lib/soft_raster.dart
//
// SoftCanvas: pure-Dart CPU rasterizer for the export path.
//
// WHY THIS EXISTS: the exporter's render cost (~30 ms/frame at 720p
// AND 1080p) is GPU dispatch/scheduling overhead, not raster work,
// and RasterProbe proved concurrent Picture.toImage calls fully
// serialize on the raster thread (concurrent/serial 0.96) -- so the
// export loop cannot be pipelined. This class renders frames in
// software on plain isolates: zero raster-thread involvement,
// embarrassingly parallel across cores.
//
// PIXEL FORMAT: premultiplied RGBA, row-major, 4 bytes/pixel --
// byte-identical layout and alpha semantics to Flutter's rawRgba
// readback. Every FFmpeg filtergraph in frame_exporter.dart
// (unpremultiply, alpha extraction, black composite) consumes these
// frames unchanged.
//
// RENDER MODEL (mirrors VizCompositor + MaskFilter semantics):
//
//  * decay(retention, dt) is the trail: a per-pixel multiply of all four
//    channels. The GPU path draws the previous premultiplied frame
//    with paint opacity = retention. We apply continuous-time decay
//    to guarantee 60fps and 30fps exports look mathematically identical.
//
//  * Every draw op rasterizes ANTI-ALIASED COVERAGE (one float per
//    pixel) into a scratch buffer, optionally Gaussian-blurs that
//    coverage, then composites the op's color src-over ONCE.
//    Coverage accumulates with max(), so overlapping capsules at
//    polyline joints cannot double-blend -- per-segment src-over
//    would seam visibly on translucent or blurred strokes.
//
//  * blurSigma on an op == ui.MaskFilter.blur(normal, sigma) on the
//    equivalent Paint: Skia's mask blur blurs the coverage mask and
//    fills with the paint color, which is exactly this pipeline.
//    Blurring the scalar mask is also 4x cheaper than blurring RGBA.
//
// SCRATCH INVARIANT: the coverage buffer is all-zero outside an op
// in progress. Each op stamps into a tracked dirty rect, composites
// that rect, and re-zeroes it during the composite pass -- no
// full-frame clears per op.
//
// DETERMINISM: pure arithmetic on typed data; identical inputs
// produce identical bytes. No engine, no GPU, no platform branches.

import 'dart:math' as math;
import 'dart:typed_data';

class SoftCanvas {
  final int width;
  final int height;

  /// Premultiplied RGBA framebuffer. Hand this (or a copy) straight
  /// to the writer isolate; it is what toByteData(rawRgba) returned.
  final Uint8List pixels;

  // Coverage scratch + separable-blur temp, one float per pixel.
  final Float32List _cov;
  final Float32List _tmp;

  // Dirty rect of the op in progress, inclusive-exclusive.
  int _dx0 = 0, _dy0 = 0, _dx1 = 0, _dy1 = 0;

  SoftCanvas(this.width, this.height)
      : pixels = Uint8List(width * height * 4),
        _cov = Float32List(width * height),
        _tmp = Float32List(width * height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('SoftCanvas dimensions must be positive.');
    }
  }

  /// Fully transparent black. The export background: alpha formats
  /// carry it as transparency, h264SolidBlack's yuv420p drop makes
  /// it the black composite.
  void clear() {
    pixels.fillRange(0, pixels.length, 0);
  }

  /// Trail decay: multiplies every channel of every pixel by the
  /// frame-rate-independent retention value, using a FLOOR (truncate)
  /// multiply rather than round so the swept region reaches true zero.
  ///
  /// WHY FLOOR, NOT ROUND: on an 8-bit buffer a rounding multiply has
  /// fixed points. round(v*rq) == v for every v <= 0.5/(1-rq), so all
  /// low values freeze and never fade -- a permanent residual that at
  /// high retention is a visible alpha haze in the exported matte
  /// (rq=0.98 -> everything <= 25/255 sticks, ~10% alpha forever). The
  /// floor rises with fps, because rq = retention^(30*dt) climbs toward
  /// 1, so the same setting leaves MORE residual at 60fps than 30fps --
  /// which also silently broke the fps-parity claim. A truncating
  /// multiply has NO positive fixed point: floor(v*rq) <= v*rq < v for
  /// all v > 0 when rq < 1, so every value drops by at least 1 each
  /// frame and the region clears to zero. The bright body still decays
  /// as ~v*rq (the sub-1-LSB truncation is invisible there); only the
  /// deep tail changes, from a stuck plateau to a linear ramp-to-zero.
  void decay(double retention, double dt) {
    final double r30 = retention.clamp(0.0, 1.0);
    if (r30 <= 0.0) {
      clear();
      return;
    }
    if (r30 >= 1.0) return;

    // Treat the user's slider value as "retention per 1/30th of a
    // second" so the visual feel is fps-independent. R_frame = S^(30*dt).
    final double r = math.pow(r30, 30.0 * dt).toDouble();

    final double rq = (r * 255.0).round() / 255.0; // 8-bit quantized
    final Uint8List lut = Uint8List(256);
    lut[0] = 0;
    for (int i = 1; i < 256; i++) {
      // Truncate toward zero (floor for non-negative), not round.
      // For any rq < 1 this already yields <= i-1, so the trail dies.
      // min(_, i-1) only bites in the degenerate rq == 1.0 case (only
      // reachable at absurd fps): it forces a strict -1/frame so the
      // trail still clears instead of freezing. For rq < 1 it is a
      // no-op and the decay curve is untouched.
      final int decayed = (i * rq).toInt();
      lut[i] = decayed < i ? decayed : i - 1;
    }
    final Uint8List px = pixels;
    for (int i = 0; i < px.length; i++) {
      px[i] = lut[px[i]];
    }
  }

  // -------------------------------------------------------------------------
  // Draw ops
  // -------------------------------------------------------------------------

  /// Strokes a polyline with round caps and joins.
  ///
  /// [xy] is packed coordinates (x0,y0,x1,y1,...). [argb] is a
  /// straight-alpha 0xAARRGGBB int (pass Color.value). Round caps/
  /// joins fall out of stamping each segment as a capsule (distance
  /// to segment <= width/2) and max-merging coverage.
  void strokePolyline(
    Float32List xy,
    double strokeWidth,
    int argb, {
    double blurSigma = 0.0,
    bool close = false,
  }) {
    final int n = xy.length >> 1;
    if (n < 2 || strokeWidth <= 0.0 || (argb >> 24) & 0xFF == 0) return;

    final double r = strokeWidth * 0.5;
    _resetDirty();
    for (int i = 0; i < n - 1; i++) {
      final int j = i << 1;
      _stampCapsule(xy[j], xy[j + 1], xy[j + 2], xy[j + 3], r);
    }
    if (close) {
      final int j = (n - 1) << 1;
      _stampCapsule(xy[j], xy[j + 1], xy[0], xy[1], r);
    }
    _compose(argb, blurSigma);
  }

  /// Axis-aligned filled rectangle with analytic edge AA.
  void fillRect(
    double left,
    double top,
    double w,
    double h,
    int argb, {
    double blurSigma = 0.0,
  }) {
    if (w <= 0.0 || h <= 0.0 || (argb >> 24) & 0xFF == 0) return;
    final double right = left + w;
    final double bottom = top + h;

    int ix0 = left.floor();
    int iy0 = top.floor();
    int ix1 = right.ceil();
    int iy1 = bottom.ceil();
    if (ix0 < 0) ix0 = 0;
    if (iy0 < 0) iy0 = 0;
    if (ix1 > width) ix1 = width;
    if (iy1 > height) iy1 = height;
    if (ix0 >= ix1 || iy0 >= iy1) return;

    _resetDirty();
    for (int y = iy0; y < iy1; y++) {
      double cy = math.min(bottom, y + 1.0) - math.max(top, y.toDouble());
      if (cy > 1.0) cy = 1.0;
      if (cy <= 0.0) continue;
      final int row = y * width;
      for (int x = ix0; x < ix1; x++) {
        double cx = math.min(right, x + 1.0) - math.max(left, x.toDouble());
        if (cx > 1.0) cx = 1.0;
        if (cx <= 0.0) continue;
        final double c = cx * cy;
        final int idx = row + x;
        if (c > _cov[idx]) _cov[idx] = c;
      }
    }
    _growDirty(ix0, iy0, ix1, iy1);
    _compose(argb, blurSigma);
  }

  /// Filled oval inscribed in the given rect (Canvas.drawOval with a
  /// fill Paint). Exact 1px-AA circles; mild ellipses use the
  /// standard normalized-distance approximation, which is well within
  /// visual tolerance for the near-circular dots the plugins draw.
  void drawOval(
    double left,
    double top,
    double w,
    double h,
    int argb, {
    double blurSigma = 0.0,
  }) {
    if (w <= 0.0 || h <= 0.0 || (argb >> 24) & 0xFF == 0) return;
    final double rx = w * 0.5;
    final double ry = h * 0.5;
    final double cxc = left + rx;
    final double cyc = top + ry;
    final double minR = math.min(rx, ry);

    int ix0 = (left - 1.0).floor();
    int iy0 = (top - 1.0).floor();
    int ix1 = (left + w + 1.0).ceil();
    int iy1 = (top + h + 1.0).ceil();
    if (ix0 < 0) ix0 = 0;
    if (iy0 < 0) iy0 = 0;
    if (ix1 > width) ix1 = width;
    if (iy1 > height) iy1 = height;
    if (ix0 >= ix1 || iy0 >= iy1) return;

    final double invRx = 1.0 / rx;
    final double invRy = 1.0 / ry;

    _resetDirty();
    for (int y = iy0; y < iy1; y++) {
      final double ny = (y + 0.5 - cyc) * invRy;
      final int row = y * width;
      for (int x = ix0; x < ix1; x++) {
        final double nx = (x + 0.5 - cxc) * invRx;
        // Signed distance approx: (|p/r| - 1) * min(rx, ry).
        final double q = math.sqrt(nx * nx + ny * ny);
        final double d = (q - 1.0) * minR;
        double c = 0.5 - d;
        if (c <= 0.0) continue;
        if (c > 1.0) c = 1.0;
        final int idx = row + x;
        if (c > _cov[idx]) _cov[idx] = c;
      }
    }
    _growDirty(ix0, iy0, ix1, iy1);
    _compose(argb, blurSigma);
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _resetDirty() {
    _dx0 = width;
    _dy0 = height;
    _dx1 = 0;
    _dy1 = 0;
  }

  void _growDirty(int x0, int y0, int x1, int y1) {
    if (x0 < _dx0) _dx0 = x0;
    if (y0 < _dy0) _dy0 = y0;
    if (x1 > _dx1) _dx1 = x1;
    if (y1 > _dy1) _dy1 = y1;
  }

  /// Stamps one capsule (segment dilated by radius [r]) into the
  /// coverage buffer with a ~1px linear AA ramp at the edge.
  void _stampCapsule(double x0, double y0, double x1, double y1, double r) {
    final double pad = r + 1.0;
    int ix0 = (math.min(x0, x1) - pad).floor();
    int iy0 = (math.min(y0, y1) - pad).floor();
    int ix1 = (math.max(x0, x1) + pad).ceil();
    int iy1 = (math.max(y0, y1) + pad).ceil();
    if (ix0 < 0) ix0 = 0;
    if (iy0 < 0) iy0 = 0;
    if (ix1 > width) ix1 = width;
    if (iy1 > height) iy1 = height;
    if (ix0 >= ix1 || iy0 >= iy1) return;

    final double dx = x1 - x0;
    final double dy = y1 - y0;
    final double len2 = dx * dx + dy * dy;
    final double invLen2 = len2 > 0.0 ? 1.0 / len2 : 0.0;

    for (int y = iy0; y < iy1; y++) {
      final double py = y + 0.5;
      final int row = y * width;
      for (int x = ix0; x < ix1; x++) {
        final double px = x + 0.5;
        double t = ((px - x0) * dx + (py - y0) * dy) * invLen2;
        if (t < 0.0) {
          t = 0.0;
        } else if (t > 1.0) {
          t = 1.0;
        }
        final double ex = px - (x0 + t * dx);
        final double ey = py - (y0 + t * dy);
        final double d = math.sqrt(ex * ex + ey * ey);
        double c = r + 0.5 - d;
        if (c <= 0.0) continue;
        if (c > 1.0) c = 1.0;
        final int idx = row + x;
        if (c > _cov[idx]) _cov[idx] = c;
      }
    }
    _growDirty(ix0, iy0, ix1, iy1);
  }

  /// Separable Gaussian blur of the coverage buffer over the dirty
  /// rect, expanded by the kernel radius. Reads outside the expanded
  /// rect are treated as zero -- which they truly are, per the
  /// scratch invariant -- so no buffer clears are needed.
  void _blurCoverage(double sigma) {
    final int rad = (sigma * 3.0).ceil();
    if (rad < 1) return;

    // Kernel.
    final Float64List kern = Float64List(2 * rad + 1);
    final double inv2s2 = 1.0 / (2.0 * sigma * sigma);
    double sum = 0.0;
    for (int k = -rad; k <= rad; k++) {
      final double v = math.exp(-(k * k) * inv2s2);
      kern[k + rad] = v;
      sum += v;
    }
    final double invSum = 1.0 / sum;
    for (int i = 0; i < kern.length; i++) {
      kern[i] *= invSum;
    }

    // Expanded rect E, clamped to the frame.
    int ex0 = _dx0 - rad;
    int ey0 = _dy0 - rad;
    int ex1 = _dx1 + rad;
    int ey1 = _dy1 + rad;
    if (ex0 < 0) ex0 = 0;
    if (ey0 < 0) ey0 = 0;
    if (ex1 > width) ex1 = width;
    if (ey1 > height) ey1 = height;

    // Horizontal: cov -> tmp over all of E (explicitly writing zeros
    // in rows E covers beyond the stamped rect, so the vertical pass
    // never reads stale tmp inside E).
    for (int y = ey0; y < ey1; y++) {
      final int row = y * width;
      for (int x = ex0; x < ex1; x++) {
        double acc = 0.0;
        int kLo = -rad, kHi = rad;
        if (x + kLo < ex0) kLo = ex0 - x;
        if (x + kHi > ex1 - 1) kHi = ex1 - 1 - x;
        for (int k = kLo; k <= kHi; k++) {
          acc += _cov[row + x + k] * kern[k + rad];
        }
        _tmp[row + x] = acc;
      }
    }

    // Vertical: tmp -> cov over E. Reads clamped to E's rows; the
    // true value beyond them is zero (coverage never existed there).
    for (int y = ey0; y < ey1; y++) {
      final int row = y * width;
      int kLo = -rad, kHi = rad;
      if (y + kLo < ey0) kLo = ey0 - y;
      if (y + kHi > ey1 - 1) kHi = ey1 - 1 - y;
      for (int x = ex0; x < ex1; x++) {
        double acc = 0.0;
        for (int k = kLo; k <= kHi; k++) {
          acc += _tmp[(y + k) * width + x] * kern[k + rad];
        }
        _cov[row + x] = acc;
      }
    }

    _dx0 = ex0;
    _dy0 = ey0;
    _dx1 = ex1;
    _dy1 = ey1;
  }

  /// Composites [argb] src-over into the framebuffer wherever the
  /// dirty rect has coverage, re-zeroing coverage as it goes (this
  /// maintains the scratch invariant with no separate clear pass).
  void _compose(int argb, double blurSigma) {
    if (_dx1 <= _dx0 || _dy1 <= _dy0) return;
    if (blurSigma > 0.0) _blurCoverage(blurSigma);

    final double a = ((argb >> 24) & 0xFF) / 255.0;
    final int cr = (argb >> 16) & 0xFF;
    final int cg = (argb >> 8) & 0xFF;
    final int cb = argb & 0xFF;

    final Uint8List px = pixels;
    for (int y = _dy0; y < _dy1; y++) {
      int p = y * width + _dx0;
      for (int x = _dx0; x < _dx1; x++, p++) {
        final double c = _cov[p];
        if (c <= 0.0) continue;
        _cov[p] = 0.0;

        // Straight color + coverage -> premultiplied src, then
        // src-over against the premultiplied destination.
        final double sa = a * c;
        final double ia = 1.0 - sa;
        final int o = p << 2;
        px[o] = (cr * sa + px[o] * ia + 0.5).toInt();
        px[o + 1] = (cg * sa + px[o + 1] * ia + 0.5).toInt();
        px[o + 2] = (cb * sa + px[o + 2] * ia + 0.5).toInt();
        px[o + 3] = (255.0 * sa + px[o + 3] * ia + 0.5).toInt();
      }
    }
  }
}