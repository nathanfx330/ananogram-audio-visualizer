// ./lib/frame_exporter.dart
//
// Deterministic offline video bake for Visualization plugins.
//
// FIFO + Writer-Isolate Pipeline:
// Render frame -> Raw RGBA -> named FIFO -> FFmpeg.
//
// Why not Process.stdin: Dart's process stdin is an async IOSink
// serviced by the UI isolate's event loop. Each 3.7 MB (720p) frame
// gets dribbled out in pipe-buffer-sized chunks (~64 KB), every chunk
// costing an epoll wakeup on an isolate that is also running the
// Flutter engine -- measured at ~147 ms/frame against FFmpeg's proven
// 350 fps intake of the identical stream from a shell pipe. The write
// path, not FFmpeg, was the export bottleneck.
//
// Instead: a mkfifo named pipe is FFmpeg's video input, fed by a
// dedicated writer isolate doing synchronous blocking writeFromSync
// calls -- one straight syscall stream, zero event-loop involvement.
// Frames cross isolates as TransferableTypedData (buffer move, not
// copy). Backpressure is preserved twice over: the OS pipe blocks the
// writer when FFmpeg falls behind, and the render loop keeps at most
// _maxFramesInFlight un-acked frames, so RAM stays bounded.
//
// RASTER-THREAD SCHEDULING:
// After the pipe fix, profiling showed render at ~44 ms/frame at 720p
// -- far beyond actual raster work. Two causes addressed here:
//
//  1. Per-frame onProgress -> setState scheduled a vsync-aligned UI
//     frame on the SAME raster thread that services toImage and
//     toByteData, so every export frame's two GPU round trips could
//     each park behind a ~16 ms vsync quantum. Progress callbacks are
//     now throttled inside the exporter (_progressIntervalMs), so the
//     raster thread belongs to the export loop.
//
//  2. Readback of frame N was serialized before rendering N+1, though
//     the trail only needs N's IMAGE (which exists the moment
//     advanceAsync returns), not its bytes. toByteData(N) is now
//     kicked off un-awaited, frame N+1 renders on top of it, and N's
//     bytes are awaited after. The readback cost hides under render.
//
// RASTER PROBE (diagnostic, off by default): render still costs
// ~30 ms/frame at 720p AND 1080p -- near-identical at 2.25x the
// pixels, i.e. dispatch overhead, not raster work. _runRasterProbe
// runs RasterProbe once at export start to answer whether concurrent
// Picture.toImage calls overlap on the raster thread (pipelining the
// export loop would pay) or serialize (CPU raster path is the only
// real fix). Flip the flag, run one export, read the report, flip it
// back.
//
// ALPHA INTERPRETATION:
// Flutter's rawRgba readback is PREMULTIPLIED: every color channel is
// already scaled by its alpha. FFmpeg and every downstream consumer
// (NLE alpha defaults, luma-matte reconstruction math) assume STRAIGHT
// alpha unless told otherwise. Each format handles the mismatch at the
// point of encode:
//
//  * h264SolidBlack -- premultiplied is exactly "already composited
//    over black", so dropping the alpha plane (format=yuv420p) IS the
//    black composite. No conversion. (The old color-source + overlay
//    graph was wrong for the opposite reason: overlay assumes straight
//    alpha, so premultiplied pixels got alpha applied twice, darkening
//    the entire glow falloff.)
//
//  * proresAlpha -- ProRes 4444 alpha is interpreted as straight by
//    default in every NLE/compositor. Encoding premultiplied pixels
//    untagged bakes a one-stop darkening into every glow edge unless
//    the artist manually reinterprets the footage as premultiplied/
//    matted-black. The graph runs unpremultiply=inplace=1 before the
//    encoder, so the file matches the default interpretation: drop it
//    in the comp, alpha just works.
//
//  * lumaMatte -- a fill+matte pair reconstructs as fill x matte in
//    the compositor. That math is only correct when the fill carries
//    STRAIGHT color; a premultiplied fill gets alpha multiplied in a
//    second time. The graph unpremultiplies once, then splits: the
//    straight branch becomes the color pass, its alpha plane becomes
//    the matte pass. Zero-alpha pixels come out black from
//    unpremultiply (0/0 defined as 0), which is harmless -- the matte
//    zeroes them anyway.
//
// FORMAT PINNING (the negotiation fix): unpremultiply's output format
// list and alphaextract's input format list failed to negotiate a
// common format, killing the lumaMatte graph at runtime ("The
// following filters could not choose their formats"). An explicit
// format=rgba pin immediately after unpremultiply resolves it -- and
// is applied in the proresAlpha graph too, so both alpha graphs hand
// their downstream a declared, known format instead of trusting the
// negotiator.
//
// Known tradeoff of unpremultiply: dividing by near-zero alpha
// amplifies quantization noise in the faintest falloff pixels. At
// 10-bit 4:4:4 (ProRes) and for synthetic glows this is invisible;
// it is the standard cost of every straight-alpha export.
//
// INSTRUMENTATION: per-stage millisecond totals (render / readback /
// wait) are printed every _timingReportInterval frames so the real
// bottleneck is measurable, not guessed. Note readback measures only
// the residual await AFTER overlapping with the next render. The same
// stages are also accumulated across the WHOLE run and written into
// the sidecar as a "performance" block (ExportPerformance) -- the
// terminal report dies in stdout on a compiled release binary, so the
// sidecar is where true pipeline speed vs realtime gets recorded.
// Wall time for that block stops when the last frame is acked by the
// writer (pipeline done), before FFmpeg's trailing-frame finalize.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'manifest.dart';
import 'raster_probe.dart';
import 'visualization.dart';

enum VideoExportFormat {
  lumaMatte,
  proresAlpha,
  h264SolidBlack,
}

class ExportCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ExportResult {
  final bool success;
  final bool cancelled;
  final String? error;
  final int framesWritten;
  final String outputPath;

  const ExportResult({
    required this.success,
    required this.cancelled,
    required this.framesWritten,
    required this.outputPath,
    this.error,
  });
}

// ---------------------------------------------------------------------------
// Writer isolate
// ---------------------------------------------------------------------------

/// Entry point for the FIFO writer isolate.
///
/// Protocol (isolate -> main, via replyPort):
///   SendPort        first message: the isolate's inbox
///   'ready'         FIFO opened for writing (FFmpeg attached)
///   'ack'           one frame fully written
///   'done'          close requested and FIFO closed cleanly
///   'error:<msg>'   any failure (EPIPE after FFmpeg death, etc.)
///
/// Protocol (main -> isolate, via inbox):
///   TransferableTypedData   one raw RGBA frame
///   null                    no more frames; close and exit
void _fifoWriterMain((String, SendPort) setup) {
  final String fifoPath = setup.$1;
  final SendPort reply = setup.$2;

  final ReceivePort inbox = ReceivePort();
  reply.send(inbox.sendPort);

  RandomAccessFile? raf;

  // Opening a FIFO for write blocks until the reader (FFmpeg) opens
  // its end -- that block happens here, in this isolate, never on the
  // UI isolate.
  try {
    raf = File(fifoPath).openSync(mode: FileMode.writeOnly);
  } catch (e) {
    reply.send('error:FIFO open failed: $e');
    inbox.close();
    return;
  }
  reply.send('ready');

  inbox.listen((dynamic msg) {
    if (msg == null) {
      try {
        raf!.closeSync();
        reply.send('done');
      } catch (e) {
        reply.send('error:FIFO close failed: $e');
      }
      inbox.close();
      return;
    }
    try {
      final Uint8List bytes =
          (msg as TransferableTypedData).materialize().asUint8List();
      // Synchronous blocking write: the OS pipe provides backpressure
      // by blocking this isolate, costing the render loop nothing.
      raf!.writeFromSync(bytes);
      reply.send('ack');
    } catch (e) {
      // EPIPE when FFmpeg dies/cancels lands here.
      try {
        raf!.closeSync();
      } catch (_) {}
      reply.send('error:FIFO write failed: $e');
      inbox.close();
    }
  });
}

// ---------------------------------------------------------------------------
// Exporter
// ---------------------------------------------------------------------------

/// One rendered frame whose GPU->CPU readback is in flight.
class _InFlightReadback {
  final ui.Image frame;
  final Future<ByteData?> bytes;
  final int index;
  _InFlightReadback(this.frame, this.bytes, this.index);
}

class FrameExporter {
  static const String exportDir = 'export';

  // Diagnostic: run RasterProbe once at export start (see header).
  // Leave true for production; costs a few hundred ms when on.
  static const bool _runRasterProbe = false;

  // NVENC flags used by real exports.
  static const String _nvencPreset = 'p6';
  static const String _nvencCq = '18';

  // libx264 preset. veryfast is ~2x the encode speed of fast; for
  // synthetic graphics at crf 18 the quality difference is invisible.
  static const String _x264Preset = 'veryfast';

  // Max frames sent to the writer isolate but not yet acked. 2 =
  // render(N+1) overlaps write/encode(N) with bounded RAM.
  static const int _maxFramesInFlight = 2;

  // Minimum wall-clock ms between onProgress callbacks. Every
  // per-frame callback used to setState -> schedule a vsync-aligned
  // UI frame on the raster thread the export needs; throttling keeps
  // the bar smooth (~8 Hz) without contending for that thread.
  static const int _progressIntervalMs = 125;

  // Print stage timings every N frames (0 disables).
  static const int _timingReportInterval = 60;

  static bool? _nvencVerified;

  static Future<bool> _isFfmpegAvailable() async {
    try {
      final ProcessResult r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _nvencWorks() async {
    final bool? cached = _nvencVerified;
    if (cached != null) return cached;
    bool ok = false;
    try {
      final ProcessResult listed = await Process.run('ffmpeg', ['-encoders']);
      if (listed.exitCode == 0 && (listed.stdout as String).contains('h264_nvenc')) {
        final ProcessResult test = await Process.run('ffmpeg', [
          '-v', 'error',
          '-f', 'lavfi',
          '-i', 'nullsrc=s=256x256:d=0.1',
          '-c:v', 'h264_nvenc',
          '-preset', _nvencPreset,
          '-cq', _nvencCq,
          '-f', 'null',
          '-',
        ]);
        ok = test.exitCode == 0;
      }
    } catch (_) {
      ok = false;
    }
    _nvencVerified = ok;
    return ok;
  }

  static Future<ExportResult> export({
    required Visualization viz,
    required Float32List audio,
    required int sampleRate,
    required double durationSec,
    required String sourcePath,
    required double dampening,
    required WaveformSettings settings,
    required int fps,
    required int width,
    required int height,
    required VideoExportFormat format,
    bool allowNvenc = false,
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
    ExportCancelToken? cancelToken,
  }) async {
    if (!await _isFfmpegAvailable()) {
      return const ExportResult(
        success: false, cancelled: false, framesWritten: 0, outputPath: '',
        error: 'ffmpeg not found on system PATH.',
      );
    }

    // Diagnostic probe: prints scheduling report, exports normally after.
    if (_runRasterProbe) {
      await RasterProbe.run(width, height);
    }

    final int frameCount = (durationSec * fps).ceil();
    final String project = ExportRecord.projectNameFromPath(sourcePath);

    final Directory dir = Directory(exportDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final bool useNvenc = allowNvenc && await _nvencWorks();
    final String h264Codec = useNvenc ? 'h264_nvenc' : 'libx264';
    final String h264Preset = useNvenc ? _nvencPreset : _x264Preset;

    String actualOutputPath = '$exportDir/$project.mov';
    String? mattePath;
    String videoCodec;

    // --- Create the FIFO FFmpeg will read video from ---
    final String fifoPath = '$exportDir/.ananogram_fifo_$pid';
    try {
      final File f = File(fifoPath);
      if (f.existsSync()) f.deleteSync();
      final ProcessResult mk = await Process.run('mkfifo', [fifoPath]);
      if (mk.exitCode != 0) {
        return ExportResult(
          success: false, cancelled: false, framesWritten: 0, outputPath: '',
          error: 'mkfifo failed: ${mk.stderr}',
        );
      }
    } catch (e) {
      return ExportResult(
        success: false, cancelled: false, framesWritten: 0, outputPath: '',
        error: 'mkfifo unavailable: $e',
      );
    }

    // Raw RGBA video from the FIFO, audio from the source file.
    final List<String> args = [
      '-y',
      '-v', 'error',
      '-nostats',
      '-nostdin',
      '-f', 'rawvideo',
      '-pix_fmt', 'rgba',
      '-s', '${width}x${height}',
      '-framerate', '$fps',
      '-i', fifoPath,   // Input 0: FIFO (Video)
      '-i', sourcePath, // Input 1: Source File (Audio)
    ];

    switch (format) {
      case VideoExportFormat.lumaMatte:
        actualOutputPath = actualOutputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        mattePath = actualOutputPath.replaceAll('.mp4', '_matte.mp4');
        videoCodec = h264Codec;
        args.addAll([
          // Unpremultiply ONCE, pin rgba (unpremultiply/alphaextract
          // fail format negotiation without it), then split. Fill =
          // straight color (alpha dropped by yuv420p), matte = the
          // alpha plane. fill x matte in the comp reconstructs the
          // plate exactly; a premultiplied fill would apply alpha
          // twice.
          '-filter_complex',
          '[0:v]unpremultiply=inplace=1,format=rgba,split=2[fg][fa]; '
              '[fg]format=yuv420p[color]; '
              '[fa]alphaextract,format=yuv420p[matte]',
          '-map', '[color]', '-map', '1:a',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18', '-threads', '0'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-c:a', 'aac', '-b:a', '320k', '-shortest',
          actualOutputPath,
          '-map', '[matte]',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18', '-threads', '0'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-an', mattePath,
        ]);
        break;

      case VideoExportFormat.proresAlpha:
        actualOutputPath = actualOutputPath.replaceAll(RegExp(r'\.mp4$'), '.mov');
        videoCodec = 'prores_ks';
        args.addAll([
          // ProRes 4444 alpha defaults to STRAIGHT interpretation in
          // every NLE. Convert the premultiplied readback to straight
          // at encode so the file matches that default -- no manual
          // "premultiplied / matted with black" reinterpretation
          // needed in the comp. format=rgba pins the graph output to
          // a declared format (same negotiation class of failure as
          // the lumaMatte graph).
          '-filter_complex',
          '[0:v]unpremultiply=inplace=1,format=rgba[straight]',
          '-map', '[straight]', '-map', '1:a',
          '-c:v', 'prores_ks', '-profile:v', '4444',
          '-qscale:v', '11', '-pix_fmt', 'yuva444p10le',
          '-threads', '0', '-c:a', 'pcm_s16le', '-shortest',
          actualOutputPath,
        ]);
        break;

      case VideoExportFormat.h264SolidBlack:
        actualOutputPath = actualOutputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        videoCodec = h264Codec;
        args.addAll([
          // Premultiplied input: dropping alpha IS the black composite.
          // The one format where NO unpremultiply is correct.
          '-filter_complex',
          '[0:v]format=yuv420p[color]',
          '-map', '[color]', '-map', '1:a',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18', '-threads', '0'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-c:a', 'aac', '-b:a', '320k', '-shortest',
          actualOutputPath,
        ]);
        break;
    }

    // --- Spawn writer isolate (it blocks opening the FIFO) ---
    final ReceivePort fromWriter = ReceivePort();
    final Completer<SendPort> portC = Completer<SendPort>();
    final Completer<void> readyC = Completer<void>();
    final Completer<void> doneC = Completer<void>();
    String? writerError;
    int pendingAcks = 0;
    Completer<void>? ackSlot;

    fromWriter.listen((dynamic msg) {
      if (msg is SendPort) {
        if (!portC.isCompleted) portC.complete(msg);
      } else if (msg == 'ready') {
        if (!readyC.isCompleted) readyC.complete();
      } else if (msg == 'ack') {
        pendingAcks--;
        ackSlot?.complete();
        ackSlot = null;
      } else if (msg == 'done') {
        if (!doneC.isCompleted) doneC.complete();
      } else if (msg is String && msg.startsWith('error:')) {
        writerError = msg.substring(6);
        if (!readyC.isCompleted) readyC.complete();
        if (!doneC.isCompleted) doneC.complete();
        ackSlot?.complete();
        ackSlot = null;
      }
    });

    final Isolate writerIsolate =
        await Isolate.spawn(_fifoWriterMain, (fifoPath, fromWriter.sendPort));

    // --- Start FFmpeg (opens the FIFO read end, releasing the writer) ---
    final Process proc = await Process.start('ffmpeg', args);

    bool procDead = false;
    final Completer<int> exitC = Completer<int>();
    unawaited(proc.exitCode.then((int code) {
      procDead = true;
      exitC.complete(code);
    }));

    final StringBuffer errBuf = StringBuffer();
    proc.stderr.transform(utf8.decoder).listen(errBuf.write);

    // Cleanup helper: tear down FFmpeg, writer isolate, and the FIFO.
    Future<void> teardown() async {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      // If the writer is still blocked opening the FIFO (FFmpeg never
      // attached), briefly open the read end to release it.
      if (!readyC.isCompleted) {
        try {
          final RandomAccessFile r =
              File(fifoPath).openSync(mode: FileMode.read);
          r.closeSync();
        } catch (_) {}
      }
      writerIsolate.kill(priority: Isolate.immediate);
      fromWriter.close();
      try {
        final File f = File(fifoPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    final SendPort toWriter = await portC.future;

    viz.reset();
    final VizCompositor compositor = VizCompositor(width: width, height: height);
    final double dt = 1.0 / fps;

    onStatus?.call('Rendering & Baking Video...');

    int renderedFrames = 0;

    // Readback in flight: frame N's toByteData resolves while frame
    // N+1 renders. Its ui.Image must stay alive until the bytes land.
    _InFlightReadback? inFlight;

    // Stage timing accumulators (ms). The window set resets at every
    // console report; the total set runs the whole bake and feeds the
    // sidecar performance block.
    final Stopwatch sw = Stopwatch();
    double msRender = 0, msReadback = 0, msWait = 0;
    double totalRender = 0, totalReadback = 0, totalWait = 0;
    double pipelineWallSec = 0; // frozen when the writer reports 'done'
    final Stopwatch wall = Stopwatch()..start();
    int lastProgressMs = -_progressIntervalMs;

    // Resolves the in-flight readback: awaits bytes, disposes the
    // image, hands the frame to the writer, updates progress/timing.
    Future<void> resolveInFlight() async {
      final _InFlightReadback f = inFlight!;
      inFlight = null;

      sw..reset()..start();
      final ByteData? rawBytes = await f.bytes;
      f.frame.dispose();
      final double readbackMs = sw.elapsedMicroseconds / 1000.0;
      msReadback += readbackMs;
      totalReadback += readbackMs;

      if (rawBytes == null) {
        throw Exception('Failed to extract raw pixels at frame ${f.index}.');
      }
      final Uint8List bytes = rawBytes.buffer
          .asUint8List(rawBytes.offsetInBytes, rawBytes.lengthInBytes);

      // Wait for an in-flight writer slot, then hand off. The writer
      // isolate owns the blocking syscall; this measures backpressure
      // plus transferable packing only.
      sw..reset()..start();
      while (pendingAcks >= _maxFramesInFlight && writerError == null) {
        ackSlot = Completer<void>();
        await ackSlot!.future;
      }
      if (writerError != null) {
        throw Exception(
            'Frame writer failed: $writerError\n${errBuf.toString().trim()}');
      }
      toWriter.send(TransferableTypedData.fromList([bytes]));
      pendingAcks++;
      final double waitMs = sw.elapsedMicroseconds / 1000.0;
      msWait += waitMs;
      totalWait += waitMs;

      renderedFrames++;

      // Throttled progress: at most one UI frame per interval, so the
      // raster thread stays available to the export loop.
      final int nowMs = wall.elapsedMilliseconds;
      if (nowMs - lastProgressMs >= _progressIntervalMs ||
          renderedFrames == frameCount) {
        lastProgressMs = nowMs;
        onProgress?.call(renderedFrames, frameCount);
        // One event-loop yield so the scheduled UI frame can actually
        // run; timer-free, no 1 ms floor.
        await Future<void>(() {});
      }

      if (_timingReportInterval > 0 &&
          renderedFrames % _timingReportInterval == 0) {
        final double n = _timingReportInterval.toDouble();
        final double fpsNow =
            renderedFrames / (wall.elapsedMilliseconds / 1000.0);
        print('[export] frame $renderedFrames/$frameCount  '
            'render ${(msRender / n).toStringAsFixed(1)}ms  '
            'readback ${(msReadback / n).toStringAsFixed(1)}ms  '
            'wait ${(msWait / n).toStringAsFixed(1)}ms  '
            '| ${fpsNow.toStringAsFixed(1)} fps '
            '(${(fpsNow / fps).toStringAsFixed(2)}x realtime)');
        msRender = 0;
        msReadback = 0;
        msWait = 0;
      }
    }

    try {
      // Wait for the writer to attach to FFmpeg before rendering.
      await readyC.future;
      if (writerError != null) {
        throw Exception('Writer failed to attach: $writerError');
      }

      for (int i = 0; i < frameCount; i++) {
        if (cancelToken?.isCancelled ?? false) {
          inFlight?.frame.dispose();
          await teardown();
          return ExportResult(success: false, cancelled: true, framesWritten: renderedFrames, outputPath: actualOutputPath);
        }
        if (procDead) throw Exception('FFmpeg died during encode (at frame $i)\n${errBuf.toString().trim()}');
        if (writerError != null) throw Exception('Frame writer failed: $writerError\n${errBuf.toString().trim()}');

        final VizContext ctx = VizContext(
          audio: audio, sampleRate: sampleRate, t: i / fps, frameIndex: i,
          dt: dt, width: width, height: height, dampening: dampening, settings: settings,
        );

        // --- Render frame i (compositor owns retained frames) ---
        sw..reset()..start();
        final ui.Image frame = await compositor.advanceAsync(viz, ctx, isExport: true);
        final double renderMs = sw.elapsedMicroseconds / 1000.0;
        msRender += renderMs;
        totalRender += renderMs;

        // --- Kick off frame i's readback WITHOUT awaiting it ---
        final Future<ByteData?> bytesF =
            frame.toByteData(format: ui.ImageByteFormat.rawRgba);

        // --- Resolve frame i-1's readback (overlapped with render i) ---
        if (inFlight != null) await resolveInFlight();

        inFlight = _InFlightReadback(frame, bytesF, i);
      }

      // Drain the final frame's readback.
      if (inFlight != null) await resolveInFlight();

      // Tell the writer to close the FIFO once all frames are acked,
      // then wait for FFmpeg to finish the trailing frames.
      toWriter.send(null);
      await doneC.future;
      if (writerError != null) {
        throw Exception('Frame writer failed during close: $writerError');
      }

      // Pipeline complete: every frame rendered, read back, and acked
      // by the writer. Freeze the performance clock here -- FFmpeg's
      // trailing finalize below is container bookkeeping, not
      // pipeline throughput.
      pipelineWallSec = wall.elapsedMicroseconds / 1e6;

      onStatus?.call('Finalizing File...');

      while (!exitC.isCompleted) {
        if (cancelToken?.isCancelled ?? false) {
          await teardown();
          return ExportResult(success: false, cancelled: true, framesWritten: renderedFrames, outputPath: actualOutputPath);
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final int exitCode = await exitC.future;

      if (exitCode != 0) {
        throw Exception('FFmpeg failed with code $exitCode\n${errBuf.toString().trim()}');
      }

      onProgress?.call(frameCount, frameCount);

    } catch (e) {
      print('Export Error: $e');
      inFlight?.frame.dispose();
      await teardown();
      return ExportResult(
        success: false, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath,
        error: e.toString(),
      );
    } finally {
      compositor.dispose();
    }

    // Success path cleanup: writer already exited via 'done'; FFmpeg
    // already exited; remove the FIFO and close the port.
    fromWriter.close();
    try {
      final File f = File(fifoPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}

    // Whole-run performance block for the sidecar.
    ExportPerformance? performance;
    if (renderedFrames > 0 && pipelineWallSec > 0) {
      final double n = renderedFrames.toDouble();
      final double exportFps = renderedFrames / pipelineWallSec;
      performance = ExportPerformance(
        exportWallSec: pipelineWallSec,
        exportFps: exportFps,
        realtimeFactor: exportFps / fps,
        avgRenderMs: totalRender / n,
        avgReadbackMs: totalReadback / n,
        avgWriteWaitMs: totalWait / n,
      );
    }

    // Save Manifest sidecar. style is a pure WaveformSettings
    // snapshot; the matte path is first-class record data.
    final ExportRecord record = ExportRecord(
      project: project, sourcePath: File(sourcePath).absolute.path,
      outputPath: File(actualOutputPath).absolute.path,
      mattePath: mattePath != null ? File(mattePath).absolute.path : null,
      visualization: viz.name,
      format: format.name, videoCodec: videoCodec, nvencUsed: videoCodec == 'h264_nvenc',
      fps: fps, frameCount: renderedFrames, width: width, height: height,
      dampening: dampening, audioDurationSec: durationSec, style: settings.toJson(),
      performance: performance,
    );
    record.writeSidecar();

    return ExportResult(success: true, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath);
  }
}