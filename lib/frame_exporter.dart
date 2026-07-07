// ./lib/frame_exporter.dart
//
// Deterministic offline video bake for Visualization plugins.
//
// TWO RENDER PATHS:
//
//  * CPU raster (preferred): if the active plugin has a
//    SoftVisualization port, the bake runs as a PARALLEL POOL of
//    worker isolates (soft_bake_pool.dart) -- each renders a
//    contiguous frame chunk in pure Dart via SoftCanvas straight into
//    its own FIFO + ffmpeg, producing a lossless-alpha segment. The
//    segments concat (stream-copy) into one intermediate; a single
//    final ffmpeg pass then runs the format-specific alpha graph and
//    muxes audio. RasterProbe proved concurrent Picture.toImage calls
//    fully serialize on the raster thread (concurrent/serial 0.96,
//    ~82 ms scheduling tax/call), so the GPU dispatch cost cannot be
//    pipelined away; software render on N plain isolates sidesteps it
//    AND scales across cores.
//
//  * GPU (fallback): unported plugins take the original single-FIFO +
//    writer-isolate pipeline below, unchanged.
//
// CPU PATH ARCHITECTURE (segments -> concat -> final pass):
//
// The parallel pool cannot share one ordered output stream without
// stalling non-leading workers (see soft_bake_pool.dart header), so
// each worker encodes an independent segment. That forces a choice
// about WHERE the format-specific alpha work runs:
//
//   Segments are encoded LOSSLESS with alpha preserved (FFV1 in
//   gbrap -- planar RGB + alpha). No unpremultiply, no matte
//   extraction, no black composite, no ProRes conversion happens
//   per-segment -- segments are a faithful, bit-exact carrier of the
//   premultiplied RGBA the workers stamped. ALL format-specific alpha
//   handling runs ONCE, in a single final pass, on the concatenated
//   intermediate.
//
//   WHY gbrap AND NOT yuva444p: FFV1 is lossless over whatever pixel
//   format it is handed, but rgba -> yuva444p is itself a LOSSY
//   colorspace conversion at 8 bits -- the RGB<->YUV matrices do not
//   round-trip bit-exactly, so segments encoded through YUV reach the
//   final pass slightly perturbed relative to what the GPU path feeds
//   its inline graphs. That was the known CPU/GPU pixel divergence.
//   gbrap is FFV1-native planar RGB with alpha: rgba -> gbrap is a
//   pure channel reshuffle, zero arithmetic, so the final pass sees
//   byte-identical input on both render paths. Cost: RGB compresses
//   worse than YUV under FFV1, so the transient intermediates are
//   somewhat larger. They are deleted after the final pass; the size
//   is rented, the correctness is kept.
//
// This keeps the pool dumb (render -> lossless segment, nothing
// format-aware) and confines every alpha decision to one place -- the
// _finalPassArgs builder -- which runs the SAME filtergraphs the GPU
// path uses inline, just relocated to the end of the CPU pipeline.
// The cost is large temporary intermediates (lossless RGB + alpha),
// but they are transient and deleted after the final pass. Because
// the alpha survives losslessly to the final pass, lumaMatte's matte
// is generated there from the intermediate's own alpha plane -- no
// second set of segments, no special-casing in the pool.
//
// Concat is the ffmpeg concat DEMUXER in stream-copy mode: every
// segment is an independent FFV1 encode with identical parameters, so
// the segments splice frame-exact with no re-encode.
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
// in premultiplied space to match it byte-for-byte in semantics. On
// the CPU path the premultiplied frames ride through the lossless
// segments and concat untouched, reaching the final pass exactly as
// stamped. FFmpeg and every downstream consumer (NLE alpha defaults,
// luma-matte reconstruction math) assume STRAIGHT alpha unless told
// otherwise. Each format handles the mismatch at the point of encode
// (GPU: inline; CPU: in the final pass):
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
// INSTRUMENTATION: the GPU path prints per-stage millisecond totals
// every _timingReportInterval frames (tag [export]) and accumulates
// whole-run into the sidecar. The CPU pool returns aggregated
// SoftBakeStats (pooled per-frame render + write, real parallel wall
// time, parallel efficiency, replay cost, trail-warmup cost, and a
// per-worker breakdown). Both feed the sidecar "performance" block. On
// the CPU path avg_readback_ms is 0.0 by construction (no GPU readback
// exists) and avg_write_wait_ms is the pooled blocking FIFO write.
// Wall time is the pool's parallel wall (first worker start to last
// worker done), excluding concat + final pass, which are container/
// encode bookkeeping rather than render throughput. The per-worker
// breakdown is printed at bake end to expose stragglers and encode
// starvation while tuning worker count.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'manifest.dart';
import 'raster_probe.dart';
import 'soft_bake_pool.dart';
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

  // Per-segment FFV1 encoder threads. FFV1 slice threading is cheap
  // but competes with the render isolates for cores; keep it low so
  // the cores belong to render. 1 = no intra-segment threading; the
  // parallelism is across segments, not within them.
  static const String _ffv1Threads = '1';

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
    required int workerCount,
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

    // --- Route: CPU parallel pool if the plugin has a soft port ---
    if (softVisualizationFor(viz.name) != null) {
      return _exportSoftParallel(
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
        workerCount: workerCount,
        useNvenc: useNvenc,
        h264Codec: h264Codec,
        h264Preset: h264Preset,
        onProgress: onProgress,
        onStatus: onStatus,
        cancelToken: cancelToken,
      );
    }

    // ------------------------------------------------------------------
    // GPU path (fallback for unported plugins)
    // ------------------------------------------------------------------

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

        final String hexBg = '#${(settings.backgroundColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

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
  // CPU parallel path: pool -> segments -> concat -> final pass
  // ------------------------------------------------------------------

  /// FFV1 segment args: raw rgba from the worker's FIFO in, one
  /// lossless-alpha video-only segment out. No filtergraph, no audio,
  /// no format-specific work -- segments are a faithful carrier of
  /// the premultiplied RGBA the worker stamped.
  ///
  /// gbrap (FFV1-native planar RGB + alpha) is the pixel format
  /// because rgba -> gbrap is a pure channel reshuffle -- zero
  /// arithmetic, bit-exact. The previous yuva444p choice was NOT
  /// lossless end-to-end: FFV1 encoded the YUV losslessly, but the
  /// rgba -> yuva444p conversion in front of it is lossy at 8 bits
  /// (RGB<->YUV matrices don't round-trip), which was the source of
  /// the CPU/GPU pixel divergence. With gbrap the final pass sees
  /// byte-identical input on both render paths. Segments are somewhat
  /// larger (RGB compresses worse than YUV) but transient. Every
  /// segment uses identical settings, so the concat demuxer
  /// stream-copies them frame-exact.
  List<String> _segmentArgs(
      String fifoPath, String segmentPath, int chunkFrames,
      {required int fps, required int width, required int height}) {
    return <String>[
      '-y',
      '-v', 'error',
      '-nostats',
      '-nostdin',
      '-f', 'rawvideo',
      '-pix_fmt', 'rgba',
      '-s', '${width}x${height}',
      '-framerate', '$fps',
      '-i', fifoPath,
      '-frames:v', '$chunkFrames',
      '-c:v', 'ffv1',
      '-level', '3',
      '-pix_fmt', 'gbrap',
      '-threads', _ffv1Threads,
      '-an',
      segmentPath,
    ];
  }

  /// Final-pass args: the concatenated lossless intermediate ([0:v],
  /// premultiplied RGBA preserved) + the source audio ([1:a]) ->
  /// the format-specific deliverable. These filtergraphs are the
  /// SAME as the GPU path's inline graphs, relocated here to run once
  /// on the whole stream.
  List<String> _finalPassArgs({
    required String intermediatePath,
    required String sourcePath,
    required String outputPath,
    required String? mattePath,
    required VideoExportFormat format,
    required WaveformSettings settings,
    required int width,
    required int height,
    required bool useNvenc,
    required String h264Codec,
    required String h264Preset,
  }) {
    final List<String> args = <String>[
      '-y',
      '-v', 'error',
      '-nostats',
      '-nostdin',
      '-i', intermediatePath, // Input 0: lossless video (premultiplied)
      '-i', sourcePath,       // Input 1: source audio
    ];

    switch (format) {
      case VideoExportFormat.lumaMatte:
        args.addAll([
          '-filter_complex',
          '[0:v]unpremultiply=inplace=1,format=rgba,split=2[fg][fa]; '
              '[fg]format=yuv420p[color]; '
              '[fa]alphaextract,format=yuv420p[matte]',
          '-map', '[color]', '-map', '1:a',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18', '-threads', '0'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-c:a', 'aac', '-b:a', '320k', '-shortest',
          outputPath,
          '-map', '[matte]',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18', '-threads', '0'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-an', mattePath!,
        ]);
        break;

      case VideoExportFormat.proresAlpha:
        args.addAll([
          '-filter_complex',
          '[0:v]unpremultiply=inplace=1,format=rgba[straight]',
          '-map', '[straight]', '-map', '1:a',
          '-c:v', 'prores_ks', '-profile:v', '4444',
          '-qscale:v', '11', '-pix_fmt', 'yuva444p10le',
          '-threads', '0', '-c:a', 'pcm_s16le', '-shortest',
          outputPath,
        ]);
        break;

      case VideoExportFormat.h264SolidBlack:
        final String hexBg =
            '#${(settings.backgroundColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
        if (hexBg == '#000000') {
          args.addAll([
            '-filter_complex',
            '[0:v]format=yuv420p[color]',
            '-map', '[color]', '-map', '1:a',
            '-c:v', h264Codec, '-preset', h264Preset,
            if (!useNvenc) ...['-crf', '18', '-threads', '0'],
            if (useNvenc) ...['-cq', _nvencCq],
            '-c:a', 'aac', '-b:a', '320k', '-shortest',
            outputPath,
          ]);
        } else {
          args.addAll([
            '-filter_complex',
            'color=c=$hexBg:s=${width}x${height}[bg]; '
            '[0:v]unpremultiply=inplace=1,format=rgba[fg]; '
            '[bg][fg]overlay=format=yuv420p[color]',
            '-map', '[color]', '-map', '1:a',
            '-c:v', h264Codec, '-preset', h264Preset,
            if (!useNvenc) ...['-crf', '18', '-threads', '0'],
            if (useNvenc) ...['-cq', _nvencCq],
            '-c:a', 'aac', '-b:a', '320k', '-shortest',
            outputPath,
          ]);
        }
        break;
    }
    return args;
  }

  static Future<ExportResult> _exportSoftParallel({
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
    required int workerCount,
    required bool useNvenc,
    required String h264Codec,
    required String h264Preset,
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
    ExportCancelToken? cancelToken,
  }) async {
    // Resolve final output path + matte path per format (same rules
    // as the GPU path's inline replaceAll chain).
    String actualOutputPath = '$exportDir/$project.mov';
    String? mattePath;
    String videoCodec;
    switch (format) {
      case VideoExportFormat.lumaMatte:
        actualOutputPath =
            actualOutputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        mattePath = actualOutputPath.replaceAll('.mp4', '_matte.mp4');
        videoCodec = h264Codec;
        break;
      case VideoExportFormat.proresAlpha:
        actualOutputPath =
            actualOutputPath.replaceAll(RegExp(r'\.mp4$'), '.mov');
        videoCodec = 'prores_ks';
        break;
      case VideoExportFormat.h264SolidBlack:
        actualOutputPath =
            actualOutputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        videoCodec = h264Codec;
        break;
    }

    final String tag = '$pid';
    final String intermediatePath =
        '$exportDir/.ananogram_softconcat_$tag.mkv';
    final String concatListPath =
        '$exportDir/.ananogram_softlist_$tag.txt';

    // Instance needed only for the two arg-builder methods (they use
    // no instance state; a throwaway keeps them as instance methods
    // without making the whole class static-only).
    final FrameExporter self = FrameExporter._();

    final SoftBakePool pool = SoftBakePool(
      width: width,
      height: height,
      fps: fps,
      totalFrames: frameCount,
      vizName: vizName,
      audio: audio,
      sampleRate: sampleRate,
      dampening: dampening,
      settings: settings,
      workDir: exportDir,
      tag: tag,
      workerCount: workerCount,
      progressIntervalMs: _progressIntervalMs,
    );

    void deleteQuietly(String path) {
      try {
        final File f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    // --- Phase A: parallel render -> N lossless segments ---
    final SoftBakeResult bake = await pool.run(
      buildSegmentArgs: (fifo, seg, chunkFrames) => self._segmentArgs(
        fifo, seg, chunkFrames,
        fps: fps, width: width, height: height,
      ),
      isCancelled: () => cancelToken?.isCancelled ?? false,
      onProgress: onProgress,
      onStatus: onStatus,
    );

    if (!bake.success) {
      // Pool already cleaned its own segments/FIFOs on failure/cancel.
      return ExportResult(
        success: false,
        cancelled: bake.cancelled,
        framesWritten: bake.framesWritten,
        outputPath: actualOutputPath,
        error: bake.error,
      );
    }

    // From here segments exist and are ours to concat then delete.
    void cleanupSegments() {
      for (final String p in bake.segmentPaths) {
        deleteQuietly(p);
      }
    }

    try {
      // --- Phase B: concat segments (stream copy) -> intermediate ---
      onStatus?.call('Joining Segments...');
      final StringBuffer listBuf = StringBuffer();
      for (final String seg in bake.segmentPaths) {
        // concat demuxer needs absolute paths, single-quoted.
        final String abs = File(seg).absolute.path;
        listBuf.writeln("file '$abs'");
      }
      File(concatListPath).writeAsStringSync(listBuf.toString());

      if (cancelToken?.isCancelled ?? false) {
        cleanupSegments();
        deleteQuietly(concatListPath);
        return ExportResult(
          success: false, cancelled: true,
          framesWritten: bake.framesWritten, outputPath: actualOutputPath,
        );
      }

      final ProcessResult concat = await Process.run('ffmpeg', <String>[
        '-y', '-v', 'error', '-nostdin',
        '-f', 'concat', '-safe', '0',
        '-i', File(concatListPath).absolute.path,
        '-c', 'copy',
        intermediatePath,
      ]);
      if (concat.exitCode != 0) {
        cleanupSegments();
        deleteQuietly(concatListPath);
        deleteQuietly(intermediatePath);
        return ExportResult(
          success: false, cancelled: false,
          framesWritten: bake.framesWritten, outputPath: actualOutputPath,
          error: 'Segment concat failed: ${concat.stderr}',
        );
      }

      // Segments consumed; drop them and the list now.
      cleanupSegments();
      deleteQuietly(concatListPath);

      if (cancelToken?.isCancelled ?? false) {
        deleteQuietly(intermediatePath);
        return ExportResult(
          success: false, cancelled: true,
          framesWritten: bake.framesWritten, outputPath: actualOutputPath,
        );
      }

      // --- Phase C: final pass (alpha graph + audio mux) ---
      onStatus?.call('Finalizing File...');
      final List<String> finalArgs = self._finalPassArgs(
        intermediatePath: intermediatePath,
        sourcePath: sourcePath,
        outputPath: actualOutputPath,
        mattePath: mattePath,
        format: format,
        settings: settings,
        width: width,
        height: height,
        useNvenc: useNvenc,
        h264Codec: h264Codec,
        h264Preset: h264Preset,
      );
      final ProcessResult finalPass =
          await Process.run('ffmpeg', finalArgs);
      deleteQuietly(intermediatePath);

      if (finalPass.exitCode != 0) {
        return ExportResult(
          success: false, cancelled: false,
          framesWritten: bake.framesWritten, outputPath: actualOutputPath,
          error: 'Final pass failed: ${finalPass.stderr}',
        );
      }
    } catch (e) {
      cleanupSegments();
      deleteQuietly(concatListPath);
      deleteQuietly(intermediatePath);
      return ExportResult(
        success: false, cancelled: false,
        framesWritten: bake.framesWritten, outputPath: actualOutputPath,
        error: e.toString(),
      );
    }

    onProgress?.call(frameCount, frameCount);

    // --- Sidecar: renderer=cpu, pool stats -> performance block ---
    ExportPerformance? performance;
    final SoftBakeStats? st = bake.stats;
    if (st != null && st.framesRendered > 0 && st.wallSec > 0) {
      final double exportFps = st.framesRendered / st.wallSec;
      performance = ExportPerformance(
        exportWallSec: st.wallSec,
        exportFps: exportFps,
        realtimeFactor: exportFps / fps,
        avgRenderMs: st.avgRenderMs,
        avgReadbackMs: 0.0, // no GPU readback exists on this path
        avgWriteWaitMs: st.avgWriteWaitMs,
      );

      // Summary line: the headline throughput plus the tuning
      // signals -- parallel efficiency (idle-core detector), the
      // worst replay (scan-only straggler tax), and the worst warm-up
      // (trail-rebuild tax, grows with retention up to K frames).
      print('[export-cpu] pool: ${st.workerCount} workers, '
          '${st.framesRendered} frames, '
          '${st.wallSec.toStringAsFixed(2)}s wall, '
          '${exportFps.toStringAsFixed(1)} fps '
          '(${(exportFps / fps).toStringAsFixed(2)}x realtime)  '
          '| eff ${(st.parallelEfficiency * 100).toStringAsFixed(0)}%  '
          'replay avg ${st.avgReplayMs.toStringAsFixed(0)}ms '
          'max ${st.maxReplayMs.toStringAsFixed(0)}ms  '
          'warmup avg ${st.avgWarmupMs.toStringAsFixed(0)}ms '
          'max ${st.maxWarmupMs.toStringAsFixed(0)}ms');
      print('[export-cpu]   pooled per-frame: '
          'render ${st.avgRenderMs.toStringAsFixed(1)}ms  '
          'write ${st.avgWriteWaitMs.toStringAsFixed(1)}ms');

      // Per-worker breakdown: one line each so a straggler (long wall,
      // or replay/warm-up eating its time) or a starved worker (high
      // write) is immediately visible while tuning worker count.
      // renderMs/writeMs are chunk totals; per-frame divides by that
      // worker's frames. replay is scan-only catch-up; warmup is the
      // full-render trail rebuild (both grow with chunk index).
      final int nWorkers = st.perWorkerWallSec.length;
      final int framesPerWorker =
          nWorkers > 0 ? (st.framesRendered / nWorkers).round() : 0;
      for (int w = 0; w < nWorkers; w++) {
        final double wallS = st.perWorkerWallSec[w];
        final double rMs = st.perWorkerRenderMs[w];
        final double wMs = st.perWorkerWriteMs[w];
        final double repMs = st.perWorkerReplayMs[w];
        final double warmMs = st.perWorkerWarmupMs[w];
        final double perFrameR =
            framesPerWorker > 0 ? rMs / framesPerWorker : 0.0;
        final double perFrameW =
            framesPerWorker > 0 ? wMs / framesPerWorker : 0.0;
        print('[export-cpu]   worker $w: '
            'wall ${wallS.toStringAsFixed(2)}s  '
            'render ${perFrameR.toStringAsFixed(1)}ms/f  '
            'write ${perFrameW.toStringAsFixed(1)}ms/f  '
            'replay ${repMs.toStringAsFixed(0)}ms  '
            'warmup ${warmMs.toStringAsFixed(0)}ms');
      }
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
      frameCount: bake.framesWritten,
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
      framesWritten: bake.framesWritten,
      outputPath: actualOutputPath,
    );
  }

  /// Private ctor: the class is otherwise all-static, but the two
  /// final-pass/segment arg builders are instance methods (no state);
  /// _exportSoftParallel spins up one throwaway to call them.
  FrameExporter._();
}