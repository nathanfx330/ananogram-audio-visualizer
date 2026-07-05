// ./lib/frame_exporter.dart
//
// Deterministic offline video bake for Visualization plugins.
//
// TWO RENDER PATHS:
//
//  * CPU raster (preferred): if the active plugin has a
//    SoftVisualization port, the whole render+write loop runs on ONE
//    plain worker isolate -- SoftCanvas software rasterization
//    straight into blocking FIFO writes. No raster thread, no
//    toImage, no readback, no writer handoff. RasterProbe proved
//    concurrent Picture.toImage calls fully serialize on the raster
//    thread (concurrent/serial 0.96, ~82 ms scheduling tax/call), so
//    the ~30 ms/frame GPU dispatch cost cannot be pipelined away;
//    rendering in software sidesteps it entirely. Backpressure is
//    the blocking write itself. Cancellation: main kills FFmpeg, the
//    pipe's read end closes, the worker's next write EPIPEs and it
//    exits -- main reports cancelled, not failed.
//
//  * GPU (fallback): unported plugins take the original
//    FIFO + writer-isolate pipeline below, unchanged.
//
// FIFO + Writer-Isolate Pipeline (GPU path):
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
// RASTER-THREAD SCHEDULING (GPU path):
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
// RASTER PROBE (diagnostic, off by default): kept in-repo,
// flag-gated, for regression-checking future Flutter engine versions.
// Flip the flag, run one export, read the report, flip it back.
//
// ALPHA INTERPRETATION:
// Both render paths produce PREMULTIPLIED RGBA: Flutter's rawRgba
// readback is premultiplied by definition, and SoftCanvas composites
// in premultiplied space to match it byte-for-byte in semantics.
// FFmpeg and every downstream consumer (NLE alpha defaults,
// luma-matte reconstruction math) assume STRAIGHT alpha unless told
// otherwise. Each format handles the mismatch at the point of encode:
//
//  * h264SolidBlack -- if the background is exactly black, premultiplied 
//    is exactly "already composited over black", so dropping the alpha 
//    plane (format=yuv420p) IS the black composite. If the user selects 
//    a non-black background (e.g., white), we MUST unpremultiply to 
//    straight alpha first, then overlay it over a generated solid color 
//    source.
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
// INSTRUMENTATION: per-stage millisecond totals are printed every
// _timingReportInterval frames on both paths (tag [export] for GPU,
// [export-cpu] for soft) and accumulated whole-run into the sidecar
// "performance" block. On the soft path avg_readback_ms is 0.0 by
// construction (no GPU readback exists) and avg_write_wait_ms is the
// blocking FIFO write -- syscall plus encode backpressure. Wall time
// stops when the last frame hits the pipe, before FFmpeg's
// trailing-frame finalize.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'manifest.dart';
import 'raster_probe.dart';
import 'soft_raster.dart';
import 'soft_visualizations.dart';
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
// Writer isolate (GPU path)
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
// Soft bake worker isolate (CPU path)
// ---------------------------------------------------------------------------

/// Everything the CPU bake worker needs. Sent once at spawn. Audio
/// crosses as TransferableTypedData: fromList copies, materialize
/// moves -- the UI isolate's buffer stays intact, the worker pays no
/// second copy.
class _SoftBakeConfig {
  final String fifoPath;
  final SendPort reply;
  final String vizName;
  final TransferableTypedData audio;
  final int sampleRate;
  final int frameCount;
  final int fps;
  final int width;
  final int height;
  final double dampening;
  final WaveformSettings settings;

  _SoftBakeConfig({
    required this.fifoPath,
    required this.reply,
    required this.vizName,
    required this.audio,
    required this.sampleRate,
    required this.frameCount,
    required this.fps,
    required this.width,
    required this.height,
    required this.dampening,
    required this.settings,
  });
}

/// Entry point for the CPU bake worker.
///
/// Protocol (worker -> main, via reply):
///   'ready'                                    FIFO opened (FFmpeg attached)
///   ('progress', framesDone)                   throttled
///   ('done', frames, renderMs, writeMs, wallS) all frames written
///   'error:<msg>'                              any failure (EPIPE on
///                                              cancel lands here)
///
/// No inbox: the loop is synchronous (blocking writes) and cannot
/// service a port. Cancellation arrives as EPIPE when main kills
/// FFmpeg.
void _softBakeMain(_SoftBakeConfig cfg) {
  final SendPort reply = cfg.reply;

  RandomAccessFile? raf;
  try {
    raf = File(cfg.fifoPath).openSync(mode: FileMode.writeOnly);
  } catch (e) {
    reply.send('error:FIFO open failed: $e');
    return;
  }
  reply.send('ready');

  try {
    final Float32List audio = cfg.audio.materialize().asFloat32List();

    final SoftVisualization? viz = softVisualizationFor(cfg.vizName);
    if (viz == null) {
      // Registry disagreed between main and worker -- a bug, not a
      // runtime condition. Fail loudly.
      throw StateError('No soft implementation for "${cfg.vizName}".');
    }
    viz.reset();

    final SoftCanvas canvas = SoftCanvas(cfg.width, cfg.height);
    final double dt = 1.0 / cfg.fps;
    // Same clamp VizCompositor._record applies to the trail draw.
    final double retention =
        cfg.settings.trailRetention.clamp(0.0, 0.995);

    final Stopwatch sw = Stopwatch();
    final Stopwatch wall = Stopwatch()..start();
    double msRender = 0, msWrite = 0;
    double totalRender = 0, totalWrite = 0;
    int lastProgressMs = -FrameExporter._progressIntervalMs;

    for (int i = 0; i < cfg.frameCount; i++) {
      final VizContext ctx = VizContext(
        audio: audio,
        sampleRate: cfg.sampleRate,
        t: i / cfg.fps,
        frameIndex: i,
        dt: dt,
        width: cfg.width,
        height: cfg.height,
        dampening: cfg.dampening,
        settings: cfg.settings,
      );

      // Decay-then-draw, mirroring VizCompositor._record's order.
      sw..reset()..start();
      canvas.decay(retention);
      viz.render(canvas, ctx);
      final double renderMs = sw.elapsedMicroseconds / 1000.0;
      msRender += renderMs;
      totalRender += renderMs;

      // Blocking write IS the backpressure: the OS pipe parks this
      // isolate when FFmpeg falls behind. The pipe copies the bytes,
      // so mutating canvas.pixels next frame is safe.
      sw..reset()..start();
      raf.writeFromSync(canvas.pixels);
      final double writeMs = sw.elapsedMicroseconds / 1000.0;
      msWrite += writeMs;
      totalWrite += writeMs;

      final int done = i + 1;
      final int nowMs = wall.elapsedMilliseconds;
      if (nowMs - lastProgressMs >= FrameExporter._progressIntervalMs ||
          done == cfg.frameCount) {
        lastProgressMs = nowMs;
        reply.send(('progress', done));
      }

      if (FrameExporter._timingReportInterval > 0 &&
          done % FrameExporter._timingReportInterval == 0) {
        final double n = FrameExporter._timingReportInterval.toDouble();
        final double fpsNow =
            done / (wall.elapsedMilliseconds / 1000.0);
        print('[export-cpu] frame $done/${cfg.frameCount}  '
            'render ${(msRender / n).toStringAsFixed(1)}ms  '
            'write ${(msWrite / n).toStringAsFixed(1)}ms  '
            '| ${fpsNow.toStringAsFixed(1)} fps '
            '(${(fpsNow / cfg.fps).toStringAsFixed(2)}x realtime)');
        msRender = 0;
        msWrite = 0;
      }
    }

    // Pipeline done: freeze the clock before closing (FFmpeg's
    // trailing finalize is container bookkeeping, not throughput).
    final double wallSec = wall.elapsedMicroseconds / 1e6;
    raf.closeSync();
    reply.send(('done', cfg.frameCount, totalRender, totalWrite, wallSec));
  } catch (e) {
    // EPIPE after a cancel/FFmpeg death lands here; main decides
    // whether it was a cancel (token set) or a real failure.
    try {
      raf.closeSync();
    } catch (_) {}
    reply.send('error:$e');
  }
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
  static const bool _runRasterProbe = false;

  // NVENC flags used by real exports.
  static const String _nvencPreset = 'p6';
  static const String _nvencCq = '18';

  // libx264 preset. veryfast is ~2x the encode speed of fast; for
  // synthetic graphics at crf 18 the quality difference is invisible.
  static const String _x264Preset = 'veryfast';

  // Max frames sent to the writer isolate but not yet acked (GPU
  // path). 2 = render(N+1) overlaps write/encode(N) with bounded RAM.
  static const int _maxFramesInFlight = 2;

  // Minimum wall-clock ms between onProgress callbacks. On the GPU
  // path this protects the raster thread from vsync-aligned UI
  // frames; on the CPU path it just avoids message flood.
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
          // every NLE. Convert the premultiplied frames to straight
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

        final String hexBg = '#${(settings.backgroundColor.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

        if (hexBg == '#000000') {
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
        } else {
          args.addAll([
            // Non-black background: we must unpremultiply to straight alpha,
            // generate a solid color background, and composite them.
            '-filter_complex',
            'color=c=$hexBg:s=${width}x${height}[bg]; '
            '[0:v]unpremultiply=inplace=1,format=rgba[fg]; '
            '[bg][fg]overlay=format=yuv420p[color]',
            '-map', '[color]', '-map', '1:a',
            '-c:v', h264Codec, '-preset', h264Preset,
            if (!useNvenc) ...['-crf', '18', '-threads', '0'],
            if (useNvenc) ...['-cq', _nvencCq],
            '-c:a', 'aac', '-b:a', '320k', '-shortest',
            actualOutputPath,
          ]);
        }
        break;
    }

    // --- Route: CPU raster if the plugin has a soft port ---
    if (softVisualizationFor(viz.name) != null) {
      return _exportSoft(
        vizName: viz.name,
        audio: audio,
        sampleRate: sampleRate,
        durationSec: durationSec,
        sourcePath: sourcePath,
        dampening: dampening,
        settings: settings,
        fps: fps,
        width: width,
        height: height,
        format: format,
        frameCount: frameCount,
        project: project,
        ffmpegArgs: args,
        fifoPath: fifoPath,
        actualOutputPath: actualOutputPath,
        mattePath: mattePath,
        videoCodec: videoCodec,
        onProgress: onProgress,
        onStatus: onStatus,
        cancelToken: cancelToken,
      );
    }

    // ------------------------------------------------------------------
    // GPU path (fallback for unported plugins)
    // ------------------------------------------------------------------

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

    onStatus?.call('Rendering & Baking Video (GPU)...');

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
      renderer: 'gpu',
      format: format.name, videoCodec: videoCodec, nvencUsed: videoCodec == 'h264_nvenc',
      fps: fps, frameCount: renderedFrames, width: width, height: height,
      dampening: dampening, audioDurationSec: durationSec, style: settings.toJson(),
      performance: performance,
    );
    record.writeSidecar();

    return ExportResult(success: true, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath);
  }

  // ------------------------------------------------------------------
  // CPU raster path
  // ------------------------------------------------------------------

  static Future<ExportResult> _exportSoft({
    required String vizName,
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
    required int frameCount,
    required String project,
    required List<String> ffmpegArgs,
    required String fifoPath,
    required String actualOutputPath,
    required String? mattePath,
    required String videoCodec,
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
    ExportCancelToken? cancelToken,
  }) async {
    final ReceivePort fromWorker = ReceivePort();
    final Completer<void> readyC = Completer<void>();
    final Completer<void> doneC = Completer<void>();
    String? workerError;
    int framesDone = 0;
    int framesRendered = 0;
    double totalRender = 0, totalWrite = 0, pipelineWallSec = 0;

    fromWorker.listen((dynamic msg) {
      if (msg == 'ready') {
        if (!readyC.isCompleted) readyC.complete();
      } else if (msg is String && msg.startsWith('error:')) {
        workerError = msg.substring(6);
        if (!readyC.isCompleted) readyC.complete();
        if (!doneC.isCompleted) doneC.complete();
      } else if (msg is (String, int) && msg.$1 == 'progress') {
        framesDone = msg.$2;
        onProgress?.call(framesDone, frameCount);
      } else if (msg is (String, int, double, double, double) &&
          msg.$1 == 'done') {
        framesRendered = msg.$2;
        totalRender = msg.$3;
        totalWrite = msg.$4;
        pipelineWallSec = msg.$5;
        if (!doneC.isCompleted) doneC.complete();
      }
    });

    final Isolate worker = await Isolate.spawn(
      _softBakeMain,
      _SoftBakeConfig(
        fifoPath: fifoPath,
        reply: fromWorker.sendPort,
        vizName: vizName,
        audio: TransferableTypedData.fromList([audio]),
        sampleRate: sampleRate,
        frameCount: frameCount,
        fps: fps,
        width: width,
        height: height,
        dampening: dampening,
        settings: settings,
      ),
    );

    // --- Start FFmpeg (opens the FIFO read end, releasing the worker) ---
    final Process proc = await Process.start('ffmpeg', ffmpegArgs);

    final Completer<int> exitC = Completer<int>();
    unawaited(proc.exitCode.then(exitC.complete));

    final StringBuffer errBuf = StringBuffer();
    proc.stderr.transform(utf8.decoder).listen(errBuf.write);

    Future<void> teardown() async {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      // Release the worker if it's still blocked opening the FIFO.
      if (!readyC.isCompleted) {
        try {
          final RandomAccessFile r =
              File(fifoPath).openSync(mode: FileMode.read);
          r.closeSync();
        } catch (_) {}
      }
      worker.kill(priority: Isolate.immediate);
      fromWorker.close();
      try {
        final File f = File(fifoPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    onStatus?.call('Rendering & Baking Video (CPU)...');

    try {
      await readyC.future;
      if (workerError != null) {
        throw Exception('Bake worker failed to attach: $workerError');
      }

      // The worker owns the loop; main just relays progress and polls
      // for cancellation. Cancel = kill FFmpeg; the worker's blocked
      // write EPIPEs and it exits on its own.
      while (!doneC.isCompleted) {
        if (cancelToken?.isCancelled ?? false) {
          await teardown();
          return ExportResult(
            success: false,
            cancelled: true,
            framesWritten: framesDone,
            outputPath: actualOutputPath,
          );
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      if (workerError != null) {
        // If the token was set, the EPIPE is our own cancel arriving
        // back -- but the cancel branch above returns first in every
        // ordinary interleaving. Reaching here with an error means a
        // real failure (FFmpeg died, encode error, worker crash).
        throw Exception(
            'Bake worker failed: $workerError\n${errBuf.toString().trim()}');
      }

      onStatus?.call('Finalizing File...');

      while (!exitC.isCompleted) {
        if (cancelToken?.isCancelled ?? false) {
          await teardown();
          return ExportResult(
            success: false,
            cancelled: true,
            framesWritten: framesDone,
            outputPath: actualOutputPath,
          );
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final int exitCode = await exitC.future;
      if (exitCode != 0) {
        throw Exception(
            'FFmpeg failed with code $exitCode\n${errBuf.toString().trim()}');
      }

      onProgress?.call(frameCount, frameCount);
    } catch (e) {
      print('Export Error: $e');
      await teardown();
      return ExportResult(
        success: false,
        cancelled: false,
        framesWritten: framesDone,
        outputPath: actualOutputPath,
        error: e.toString(),
      );
    }

    // Success path cleanup: worker exited after 'done'; FFmpeg exited.
    fromWorker.close();
    try {
      final File f = File(fifoPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}

    ExportPerformance? performance;
    if (framesRendered > 0 && pipelineWallSec > 0) {
      final double n = framesRendered.toDouble();
      final double exportFps = framesRendered / pipelineWallSec;
      performance = ExportPerformance(
        exportWallSec: pipelineWallSec,
        exportFps: exportFps,
        realtimeFactor: exportFps / fps,
        avgRenderMs: totalRender / n,
        avgReadbackMs: 0.0, // no GPU readback exists on this path
        avgWriteWaitMs: totalWrite / n,
      );
    }

    final ExportRecord record = ExportRecord(
      project: project,
      sourcePath: File(sourcePath).absolute.path,
      outputPath: File(actualOutputPath).absolute.path,
      mattePath: mattePath != null ? File(mattePath).absolute.path : null,
      visualization: vizName,
      renderer: 'cpu',
      format: format.name,
      videoCodec: videoCodec,
      nvencUsed: videoCodec == 'h264_nvenc',
      fps: fps,
      frameCount: framesRendered,
      width: width,
      height: height,
      dampening: dampening,
      audioDurationSec: durationSec,
      style: settings.toJson(),
      performance: performance,
    );
    record.writeSidecar();

    return ExportResult(
      success: true,
      cancelled: false,
      framesWritten: framesRendered,
      outputPath: actualOutputPath,
    );
  }
}