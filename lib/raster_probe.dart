// ./lib/raster_probe.dart
//
// One-shot GPU rasterization scheduling probe.
//
// PURPOSE: the exporter measures advanceAsync (Picture.toImage) at
// ~30 ms/frame at 720p AND 1080p -- near-identical cost at 2.25x the
// pixels, which says the money is going to dispatch/scheduling
// overhead, not raster work. Before building either fix (frame
// pipelining vs a CPU raster path), this probe answers the deciding
// question:
//
//   Do two concurrent Picture.toImage requests OVERLAP on the raster
//   thread, or do they SERIALIZE?
//
//   * concurrent ~= serial   -> requests serialize; pipelining the
//     export loop buys nothing; commit to the CPU raster path.
//   * concurrent ~= serial/2 -> requests overlap; pipelining hides
//     up to a full round trip under the next frame's work and is a
//     legitimate intermediate win.
//
// Also measures toImageSync (pure raster, no async round trip) as the
// floor: the gap between it and awaited toImage is the scheduling tax
// itself, measured rather than inferred.
//
// The probe draws representative Ananogram content -- a stroked
// many-segment path with a MaskFilter blur, per the phosphor plugins
// -- at the requested export resolution. One warm-up pass runs first
// so shader compilation doesn't pollute medians.
//
// Prints a report via print(); returns nothing. Called once at export
// start behind a const flag in frame_exporter.dart. This file is a
// diagnostic: delete it or leave the flag off once the question is
// answered.

import 'dart:math' as math;
import 'dart:ui' as ui;

class RasterProbe {
  static const int _iterations = 9; // odd, for a clean median

  /// Runs the probe at [width] x [height] and prints a report.
  static Future<void> run(int width, int height) async {
    final double w = width.toDouble();
    final double h = height.toDouble();

    // --- Warm-up: compile shaders, prime caches. Not measured. ---
    {
      final ui.Picture p = _recordContent(w, h, 0);
      final ui.Image img = await p.toImage(width, height);
      img.dispose();
      p.dispose();
    }

    // --- A: toImageSync (pure raster floor) ---
    final List<double> syncMs = <double>[];
    for (int i = 0; i < _iterations; i++) {
      final ui.Picture p = _recordContent(w, h, i + 1);
      final Stopwatch sw = Stopwatch()..start();
      final ui.Image img = p.toImageSync(width, height);
      syncMs.add(sw.elapsedMicroseconds / 1000.0);
      img.dispose();
      p.dispose();
    }

    // --- B: two toImage awaited serially ---
    final List<double> serialMs = <double>[];
    for (int i = 0; i < _iterations; i++) {
      final ui.Picture p1 = _recordContent(w, h, 100 + i);
      final ui.Picture p2 = _recordContent(w, h, 200 + i);
      final Stopwatch sw = Stopwatch()..start();
      final ui.Image img1 = await p1.toImage(width, height);
      final ui.Image img2 = await p2.toImage(width, height);
      serialMs.add(sw.elapsedMicroseconds / 1000.0);
      img1.dispose();
      img2.dispose();
      p1.dispose();
      p2.dispose();
    }

    // --- C: two toImage launched together, both awaited ---
    final List<double> concurrentMs = <double>[];
    for (int i = 0; i < _iterations; i++) {
      final ui.Picture p1 = _recordContent(w, h, 300 + i);
      final ui.Picture p2 = _recordContent(w, h, 400 + i);
      final Stopwatch sw = Stopwatch()..start();
      final Future<ui.Image> f1 = p1.toImage(width, height);
      final Future<ui.Image> f2 = p2.toImage(width, height);
      final ui.Image img1 = await f1;
      final ui.Image img2 = await f2;
      concurrentMs.add(sw.elapsedMicroseconds / 1000.0);
      img1.dispose();
      img2.dispose();
      p1.dispose();
      p2.dispose();
    }

    final double syncMed = _median(syncMs);
    final double serialMed = _median(serialMs);
    final double concMed = _median(concurrentMs);
    final double perCallAsync = serialMed / 2.0;
    final double overlapRatio = serialMed > 0 ? concMed / serialMed : 0.0;

    print('[raster_probe] ${width}x$height, '
        '$_iterations iterations, medians:');
    print('[raster_probe]   A toImageSync (raster floor):   '
        '${syncMed.toStringAsFixed(1)} ms');
    print('[raster_probe]   B 2x toImage serial:            '
        '${serialMed.toStringAsFixed(1)} ms '
        '(${perCallAsync.toStringAsFixed(1)} ms/call)');
    print('[raster_probe]   C 2x toImage concurrent:        '
        '${concMed.toStringAsFixed(1)} ms');
    print('[raster_probe]   scheduling tax per call:        '
        '${(perCallAsync - syncMed).toStringAsFixed(1)} ms');
    print('[raster_probe]   concurrent/serial ratio:        '
        '${overlapRatio.toStringAsFixed(2)} '
        '(~1.0 = serialized -> CPU raster path; '
        '~0.5 = overlapped -> pipelining pays)');
  }

  /// Draws representative phosphor-plugin content: a many-segment
  /// stroked polyline in triple-stroke style, outer stroke carrying
  /// a MaskFilter blur -- the expensive pieces of a real frame.
  /// [seed] varies geometry so no caching layer can recognize a
  /// repeated picture.
  static ui.Picture _recordContent(double w, double h, int seed) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas =
        ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h));

    final math.Random rng = math.Random(seed);
    final double mid = h / 2.0;
    final ui.Path path = ui.Path()..moveTo(0, mid);
    const int points = 1200; // comparable to a waveform trace
    for (int i = 1; i < points; i++) {
      final double x = w * i / (points - 1);
      final double y =
          mid + (rng.nextDouble() * 2.0 - 1.0) * (h * 0.4);
      path.lineTo(x, y);
    }

    final ui.Paint outer = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..color = const ui.Color(0xFF1EA01E)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2.0);

    final ui.Paint midP = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..color = const ui.Color(0xFF32FF32);

    final ui.Paint core = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..color = const ui.Color(0xFFC8FFC8);

    canvas.drawPath(path, outer);
    canvas.drawPath(path, midP);
    canvas.drawPath(path, core);

    return recorder.endRecording();
  }

  static double _median(List<double> xs) {
    final List<double> s = List<double>.from(xs)..sort();
    return s[s.length ~/ 2];
  }
}