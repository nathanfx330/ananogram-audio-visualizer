// ./lib/soft_bake_pool.dart
//
// Phase 2: parallel CPU-raster bake across N worker isolates.
//
// WHY THIS SHAPE: Phase 1 put render on one plain isolate doing pure
// SoftCanvas stamping straight into a FIFO -- that alone roughly
// doubled export throughput by escaping the serialized raster thread.
// One isolate proved the per-core CPU cost is low; this claims the
// rest of the cores.
//
// The design constraint that fixes the architecture: four properties
// cannot all hold at once --
//   (1) parallel render across cores
//   (2) a single ordered output byte stream
//   (3) bounded memory
//   (4) cheap state replay to a chunk's start
// A worker reuses one SoftCanvas in place, so it cannot render frame
// N+1 until N is consumed. With one shared ordered stream that means
// non-leading workers stall until the global write frontier reaches
// their chunk -- serial with extra isolates. Buffering a whole chunk
// per worker to hide that is N x chunk x framebytes: tens of GB at
// 4K. So (2) is the property that gives.
//
// Each worker therefore owns its OWN FIFO and its OWN ffmpeg,
// encoding its contiguous frame chunk to an independent video-only
// segment. All N worker+ffmpeg pairs run fully parallel: each ffmpeg
// drains its FIFO continuously, so nothing buffers and no cross-
// worker ordering exists. Because every segment is an independent
// encode it begins on an IDR keyframe, so the caller can stitch the
// segments with the ffmpeg concat demuxer in stream-copy mode --
// frame-exact, no re-encode, no GOP seam. Audio is muxed once, at
// that final concat, by the caller.
//
// REPLAY (property 4, preserved): chunks are contiguous, so a worker
// rebuilds everything frame chunkStart needs by replaying [0,
// chunkStart) in two parts:
//
//   1. STATE catch-up, frames [0, chunkStart - K): rendering
//      SUPPRESSED -- drives the plugin's per-frame state recurrence
//      (e.g. Phosphor's _peakSmoothed AGC) without stamping pixels.
//      Scan-only (peak scan / FFT), no rasterization. The determinism
//      contract makes this state bit-identical to a serial render's.
//
//   2. TRAIL warm-up, frames [chunkStart - K, chunkStart): FULL
//      render (decay + stamp) exactly like the real loop, but NOT
//      written to the FIFO. This reconstructs the framebuffer trail a
//      serial bake would have accumulated entering chunkStart. K is
//      the exact number of frames a max-value (255) stamp survives
//      before the decay LUT floors it to zero, so every past frame
//      whose stamp could still be visible at chunkStart is replayed,
//      and older ones (drained to nothing) are not. Because the
//      decay's strict per-frame decrease drains every pre-window
//      residual to zero within the same K frames, the reconstructed
//      canvas matches a serial bake's, not just approximately.
//
//      Without this the canvas starts each chunk COLD and the trail
//      visibly builds up from black over the first K frames -- a
//      periodic dimming/pumping seam at every chunk boundary, worst
//      at high retention where the afterglow is longest (which is
//      exactly where a cold start is most wrong).
//
// K = framesToZero(rq): ~1 frame at low retention, ~33 at the default
// (215/255), up to a HARD 255 at the ceiling -- the decay LUT drops a
// max-value stamp by at least one level per frame, so K can never
// exceed 255 no matter how high retention goes. The warm-up cost thus
// scales with how long the trail actually persists (inherent), capped.
//
// REDUNDANT WORK: worker k replays k*chunkLen frames. Summed across
// the pool that is ~N*(N-1)/2 chunk-lengths, but they run in parallel,
// so the wall-time cost is one worker's replay (the last chunk's):
// mostly scan-only suppressed frames plus up to K full-render warm-up
// frames at the tail. Both are MEASURED, not asserted -- each worker
// reports suppressed-replay and warm-up milliseconds separately, and
// the pool surfaces the worst of each so a straggling last chunk (or
// a warm-up-heavy high-retention bake) is visible instead of hidden
// in the average.
//
// MEMORY: one SoftCanvas per worker (W*H*4 bytes) + OS pipe buffers.
// Flat in duration and in frame count; scales with worker count and
// resolution only.
//
// EFFICIENCY (the tuning metric): the pool computes parallel
// efficiency = (sum of per-worker busy time) / (wall * workerCount).
// 1.0 means every core was busy the whole wall; 0.5 means half the
// pool sat idle (starved encoders, or one straggler holding the wall
// while others finished). This is the number that says whether a
// given worker count actually bought its cores or just spun them.
//
// OWNERSHIP BOUNDARY: this file owns chunking, the worker isolates,
// each worker's FIFO + ffmpeg process, and the per-worker segment
// paths + stats. frame_exporter.dart owns format->args construction,
// the final concat + audio mux, cancellation policy, and the sidecar.
// The pool hands back a SoftBakeResult; it does not concat, does not
// touch audio, does not write the sidecar.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'soft_raster.dart';
import 'soft_visualizations.dart';
import 'viz_state.dart';

/// Aggregated stats from one parallel bake.
///
/// Per-frame averages (avgRenderMs, avgWriteWaitMs) are pooled across
/// all workers, weighted by frames each rendered. wallSec is the real
/// parallel wall time, first worker start to last worker done.
///
/// The tuning-critical fields:
///   parallelEfficiency -- (sum of per-worker busy time) /
///     (wallSec * workerCount). 1.0 = every core busy the whole wall;
///     lower = idle cores (encode starvation or a straggler).
///   perWorkerWallSec   -- each worker's real render+write wall only
///     (excludes suppressed replay AND trail warm-up). The spread
///     exposes stragglers.
///   perWorkerReplayMs  -- suppressed-replay cost per worker. Grows
///     with chunk index; the last worker's is the redundant-work tax.
///   avgReplayMs / maxReplayMs -- pooled and worst replay.
///   perWorkerWarmupMs  -- trail warm-up cost per worker (full-render
///     frames that rebuild the trail but aren't written). Also grows
///     with chunk index, and with retention (up to K=255 frames).
///   avgWarmupMs / maxWarmupMs -- pooled and worst warm-up.
class SoftBakeStats {
  final int workerCount;
  final int framesRendered;      // real frames (excludes suppressed replay)
  final double wallSec;          // parallel wall time across the pool
  final double avgRenderMs;      // pooled per-frame render cost
  final double avgWriteWaitMs;   // pooled per-frame blocking-write cost
  final double avgReplayMs;      // mean per-worker suppressed-replay ms
  final double maxReplayMs;      // worst (last chunk) suppressed-replay ms
  final double avgWarmupMs;      // mean per-worker trail-warmup ms
  final double maxWarmupMs;      // worst (last chunk) trail-warmup ms
  final double parallelEfficiency; // sum(busy) / (wall * workers), 0..1
  final List<double> perWorkerRenderMs;
  final List<double> perWorkerWriteMs;
  final List<double> perWorkerReplayMs;
  final List<double> perWorkerWarmupMs;
  final List<double> perWorkerWallSec;

  const SoftBakeStats({
    required this.workerCount,
    required this.framesRendered,
    required this.wallSec,
    required this.avgRenderMs,
    required this.avgWriteWaitMs,
    required this.avgReplayMs,
    required this.maxReplayMs,
    required this.avgWarmupMs,
    required this.maxWarmupMs,
    required this.parallelEfficiency,
    required this.perWorkerRenderMs,
    required this.perWorkerWriteMs,
    required this.perWorkerReplayMs,
    required this.perWorkerWarmupMs,
    required this.perWorkerWallSec,
  });
}

/// Outcome of a parallel bake. On success [segmentPaths] holds the N
/// video-only segment files in frame order (segment 0 = frames
/// [0..], segment 1 = next chunk, ...), ready for concat. On failure
/// or cancel the segments are already cleaned up and the paths list
/// is empty.
class SoftBakeResult {
  final bool success;
  final bool cancelled;
  final String? error;
  final int framesWritten;
  final List<String> segmentPaths;
  final SoftBakeStats? stats;

  const SoftBakeResult({
    required this.success,
    required this.cancelled,
    required this.framesWritten,
    required this.segmentPaths,
    this.error,
    this.stats,
  });
}

/// Per-worker instructions. One contiguous chunk [chunkStart,
/// chunkEnd) of the global frame range, plus everything needed to
/// build the same VizContext a serial bake would. Audio crosses as
/// TransferableTypedData: fromList copies out of the UI isolate,
/// materialize moves into the worker -- one copy, not two, and the
/// same immutable buffer is safe to hand to every worker (each gets
/// its own transferable wrapping the same bytes).
class _WorkerConfig {
  final int workerId;
  final String fifoPath;
  final SendPort reply;
  final String vizName;
  final TransferableTypedData audio;
  final int sampleRate;
  final int chunkStart;         // first REAL frame this worker renders
  final int chunkEnd;           // exclusive
  final int fps;
  final int width;
  final int height;
  final double dampening;
  final WaveformSettings settings;
  final int progressIntervalMs; // throttle for progress messages

  _WorkerConfig({
    required this.workerId,
    required this.fifoPath,
    required this.reply,
    required this.vizName,
    required this.audio,
    required this.sampleRate,
    required this.chunkStart,
    required this.chunkEnd,
    required this.fps,
    required this.width,
    required this.height,
    required this.dampening,
    required this.settings,
    required this.progressIntervalMs,
  });
}

/// Frames for a max-value (255) stamp to decay to exactly zero under
/// per-frame retention [rq], iterating the SAME transfer SoftCanvas'
/// decay LUT applies (floor multiply, with a forced -1/frame in the
/// degenerate rq >= 1.0 case). This is the trail warm-up window: any
/// frame older than this has a stamp that has floored to zero and so
/// cannot affect the canvas at a chunk boundary. The forced strict
/// decrease bounds the result at 255 and guarantees termination.
int _framesToZero(double rq) {
  if (rq <= 0.0) return 0;
  int v = 255;
  int m = 0;
  while (v > 0 && m < 255) {
    final int decayed = (v * rq).toInt();
    v = decayed < v ? decayed : v - 1;
    m++;
  }
  return m;
}

/// Worker isolate entry point.
///
/// Protocol (worker -> pool, via reply):
///   ('ready', workerId)
///     FIFO opened (its ffmpeg attached)
///   ('progress', workerId, framesDoneInChunk)
///     throttled
///   ('done', workerId, framesRendered, renderMs, writeMs,
///            replayMs, warmupMs, workerWallSec)
///     chunk complete; renderMs/writeMs are chunk totals, replayMs is
///     the suppressed-replay cost, warmupMs is the trail-warmup cost,
///     workerWallSec is this worker's own real render+write wall
///     (excludes replay and warm-up)
///   'error:<workerId>:<msg>'
///     any failure (EPIPE on cancel)
///
/// No inbox: the loop is synchronous blocking writes and cannot
/// service a port. Cancellation arrives as EPIPE when the pool kills
/// this worker's ffmpeg.
void _workerMain(_WorkerConfig cfg) {
  final SendPort reply = cfg.reply;

  RandomAccessFile? raf;
  try {
    raf = File(cfg.fifoPath).openSync(mode: FileMode.writeOnly);
  } catch (e) {
    reply.send('error:${cfg.workerId}:FIFO open failed: $e');
    return;
  }
  reply.send(('ready', cfg.workerId));

  try {
    final Float32List audio = cfg.audio.materialize().asFloat32List();

    final SoftVisualization? viz = softVisualizationFor(cfg.vizName);
    if (viz == null) {
      throw StateError('No soft implementation for "${cfg.vizName}".');
    }
    viz.reset();

    final SoftCanvas canvas = SoftCanvas(cfg.width, cfg.height);
    final double dt = 1.0 / cfg.fps;
    final double retention =
        cfg.settings.trailRetention.clamp(0.0, 0.995);

    // Trail warm-up window length: the exact number of frames a
    // max-value (255) stamp survives before the decay LUT floors it
    // to zero. Frames older than this contribute nothing to the
    // canvas at chunkStart, so they need only suppressed (state)
    // replay; frames inside it must be fully rendered so the trail
    // entering the real chunk matches a serial bake. Computed from
    // the SAME rq the decay LUT uses (rq is constant, since dt is).
    int warmupFrames;
    if (retention <= 0.0) {
      warmupFrames = 0; // no trail: decay clears every frame
    } else {
      final double r = math.pow(retention, 30.0 * dt).toDouble();
      final double rq = (r * 255.0).round() / 255.0;
      warmupFrames = _framesToZero(rq);
    }
    if (warmupFrames > cfg.chunkStart) warmupFrames = cfg.chunkStart;
    final int warmStart = cfg.chunkStart - warmupFrames;

    // --- Part 1: suppressed state catch-up, frames [0, warmStart) ---
    // Drive the plugin's per-frame state recurrence without stamping.
    // renderSuppressed runs the same audio analysis (peak scan / FFT)
    // render()'s first pass does, so state evolves identically -- but
    // no coverage is stamped and the framebuffer is untouched. The
    // determinism contract makes the resulting state bit-identical to
    // a serial bake's. Scan-only; timed separately as the redundant-
    // work tax.
    final Stopwatch replaySw = Stopwatch()..start();
    for (int i = 0; i < warmStart; i++) {
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
      viz.renderSuppressed(ctx);
    }
    final double replayMs = replaySw.elapsedMicroseconds / 1000.0;

    // --- Part 2: trail warm-up, frames [warmStart, chunkStart) ---
    // FULL render (decay + stamp) exactly as the real loop, but the
    // frames are NOT written to the FIFO -- they exist only to
    // rebuild the framebuffer trail a serial bake accumulates
    // entering chunkStart. This is the chunk-boundary seam fix: a
    // cold canvas here would make the trail build up from black over
    // the first K frames of every segment. render() advances state
    // once per frame just like renderSuppressed, so state evolution
    // across [0, chunkStart) is identical regardless of the split
    // point -- only the canvas is additionally warmed.
    final Stopwatch warmupSw = Stopwatch()..start();
    for (int i = warmStart; i < cfg.chunkStart; i++) {
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
      canvas.decay(retention, dt);
      viz.render(canvas, ctx);
    }
    final double warmupMs = warmupSw.elapsedMicroseconds / 1000.0;

    final Stopwatch sw = Stopwatch();
    double totalRender = 0, totalWrite = 0;
    int lastProgressMs = -cfg.progressIntervalMs;
    final Stopwatch wall = Stopwatch()..start();
    final int chunkLen = cfg.chunkEnd - cfg.chunkStart;
    int doneInChunk = 0;

    // --- Part 3: render + write the real chunk ---
    for (int i = cfg.chunkStart; i < cfg.chunkEnd; i++) {
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

      sw..reset()..start();
      canvas.decay(retention, dt);
      viz.render(canvas, ctx);
      totalRender += sw.elapsedMicroseconds / 1000.0;

      // Blocking write IS the backpressure: this worker's ffmpeg
      // parks the isolate when its encode falls behind. The pipe
      // copies the bytes, so mutating canvas.pixels next frame is safe.
      sw..reset()..start();
      raf.writeFromSync(canvas.pixels);
      totalWrite += sw.elapsedMicroseconds / 1000.0;

      doneInChunk++;
      final int nowMs = wall.elapsedMilliseconds;
      if (nowMs - lastProgressMs >= cfg.progressIntervalMs ||
          doneInChunk == chunkLen) {
        lastProgressMs = nowMs;
        reply.send(('progress', cfg.workerId, doneInChunk));
      }
    }

    final double workerWallSec = wall.elapsedMicroseconds / 1e6;
    raf.closeSync();
    reply.send(('done', cfg.workerId, chunkLen, totalRender, totalWrite,
        replayMs, warmupMs, workerWallSec));
  } catch (e) {
    try {
      raf.closeSync();
    } catch (_) {}
    reply.send('error:${cfg.workerId}:$e');
  }
}

/// The pool. Splits the frame range into N contiguous chunks, spawns
/// a worker + ffmpeg per chunk, and resolves when every segment is
/// encoded. The caller supplies a factory that builds the ffmpeg
/// argument list for one segment given (fifoPath, segmentPath, chunk
/// frame count) -- this keeps all format/codec knowledge in
/// frame_exporter.dart. The pool only knows "raw rgba in, segment
/// file out".
class SoftBakePool {
  final int width;
  final int height;
  final int fps;
  final int totalFrames;
  final String vizName;
  final Float32List audio;
  final int sampleRate;
  final double dampening;
  final WaveformSettings settings;

  /// Directory for FIFOs and segment files (the export dir).
  final String workDir;

  /// Unique tag (e.g. the pid) to namespace this bake's temp files.
  final String tag;

  final int workerCount;
  final int progressIntervalMs;

  SoftBakePool({
    required this.width,
    required this.height,
    required this.fps,
    required this.totalFrames,
    required this.vizName,
    required this.audio,
    required this.sampleRate,
    required this.dampening,
    required this.settings,
    required this.workDir,
    required this.tag,
    required this.workerCount,
    required this.progressIntervalMs,
  });

  /// Splits [totalFrames] into [n] contiguous chunks as evenly as
  /// possible; the first (totalFrames % n) chunks get one extra
  /// frame. Returns a list of (start, end) exclusive ranges. Empty
  /// chunks are dropped, so a bake with fewer frames than workers
  /// simply uses fewer workers.
  static List<(int, int)> _chunks(int totalFrames, int n) {
    final List<(int, int)> out = <(int, int)>[];
    if (totalFrames <= 0 || n <= 0) return out;
    final int base = totalFrames ~/ n;
    final int rem = totalFrames % n;
    int start = 0;
    for (int i = 0; i < n; i++) {
      final int len = base + (i < rem ? 1 : 0);
      if (len == 0) break;
      out.add((start, start + len));
      start += len;
    }
    return out;
  }

  String _fifoPathFor(int workerId) =>
      '$workDir/.ananogram_softfifo_${tag}_$workerId';

  String _segmentPathFor(int workerId) =>
      '$workDir/.ananogram_softseg_${tag}_$workerId.mov';

  /// Runs the parallel bake.
  ///
  /// [buildSegmentArgs] builds the ffmpeg args for ONE segment:
  /// given the worker's FIFO path (raw rgba video input), the segment
  /// output path, and the chunk's frame count, it returns a full
  /// ffmpeg argv that reads rawvideo from the FIFO and writes a
  /// video-only segment. NO audio (muxed at final concat), and the
  /// codec must be concat-compatible with itself across segments
  /// (it is, by construction -- identical encoder settings, each
  /// starting on an IDR frame).
  ///
  /// [isCancelled] is polled between setup steps and during the wait;
  /// on cancel the pool kills every ffmpeg (which EPIPEs the workers)
  /// and tears everything down.
  ///
  /// [onProgress] reports (globalFramesDone, totalFrames), summed
  /// across workers and throttled per worker.
  Future<SoftBakeResult> run({
    required List<String> Function(
            String fifoPath, String segmentPath, int chunkFrames)
        buildSegmentArgs,
    required bool Function() isCancelled,
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    final List<(int, int)> chunks = _chunks(totalFrames, workerCount);
    if (chunks.isEmpty) {
      return const SoftBakeResult(
        success: false, cancelled: false, framesWritten: 0,
        segmentPaths: <String>[], error: 'No frames to render.',
      );
    }
    final int n = chunks.length;

    // Per-worker temp paths and cleanup helper.
    final List<String> fifoPaths =
        List<String>.generate(n, (i) => _fifoPathFor(i));
    final List<String> segmentPaths =
        List<String>.generate(n, (i) => _segmentPathFor(i));

    void deleteQuietly(String path) {
      try {
        final File f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    void cleanupFifos() {
      for (final String p in fifoPaths) {
        deleteQuietly(p);
      }
    }

    void cleanupSegments() {
      for (final String p in segmentPaths) {
        deleteQuietly(p);
      }
    }

    // --- Per-worker coordination state ---
    final ReceivePort fromWorkers = ReceivePort();
    final List<Completer<void>> readyC =
        List<Completer<void>>.generate(n, (_) => Completer<void>());
    final List<Completer<void>> doneC =
        List<Completer<void>>.generate(n, (_) => Completer<void>());
    final List<int> perWorkerDone = List<int>.filled(n, 0);
    final List<double> perWorkerRenderMs = List<double>.filled(n, 0);
    final List<double> perWorkerWriteMs = List<double>.filled(n, 0);
    final List<double> perWorkerReplayMs = List<double>.filled(n, 0);
    final List<double> perWorkerWarmupMs = List<double>.filled(n, 0);
    final List<double> perWorkerWallSec = List<double>.filled(n, 0);
    final List<int> perWorkerFrames = List<int>.filled(n, 0);
    String? firstError;

    fromWorkers.listen((dynamic msg) {
      if (msg is (String, int) && msg.$1 == 'ready') {
        final int id = msg.$2;
        if (!readyC[id].isCompleted) readyC[id].complete();
      } else if (msg is (String, int, int) && msg.$1 == 'progress') {
        final int id = msg.$2;
        perWorkerDone[id] = msg.$3;
        if (onProgress != null) {
          int sum = 0;
          for (final int d in perWorkerDone) {
            sum += d;
          }
          onProgress(sum, totalFrames);
        }
      } else if (msg is (String, int, int, double, double, double, double, double) &&
          msg.$1 == 'done') {
        final int id = msg.$2;
        perWorkerFrames[id] = msg.$3;
        perWorkerRenderMs[id] = msg.$4;
        perWorkerWriteMs[id] = msg.$5;
        perWorkerReplayMs[id] = msg.$6;
        perWorkerWarmupMs[id] = msg.$7;
        perWorkerWallSec[id] = msg.$8;
        perWorkerDone[id] = msg.$3;
        if (!doneC[id].isCompleted) doneC[id].complete();
      } else if (msg is String && msg.startsWith('error:')) {
        // Format: error:<workerId>:<message>
        final int firstColon = msg.indexOf(':');
        final int secondColon = msg.indexOf(':', firstColon + 1);
        int id = -1;
        if (secondColon > firstColon) {
          id = int.tryParse(
                  msg.substring(firstColon + 1, secondColon)) ??
              -1;
        }
        firstError ??= (id >= 0 && secondColon > 0)
            ? msg.substring(secondColon + 1)
            : msg.substring(firstColon + 1);
        if (id >= 0) {
          if (!readyC[id].isCompleted) readyC[id].complete();
          if (!doneC[id].isCompleted) doneC[id].complete();
        } else {
          for (int i = 0; i < n; i++) {
            if (!readyC[i].isCompleted) readyC[i].complete();
            if (!doneC[i].isCompleted) doneC[i].complete();
          }
        }
      }
    });

    final List<Isolate> isolates = <Isolate>[];
    final List<Process> procs = <Process>[];
    final List<Completer<int>> exitC =
        List<Completer<int>>.generate(n, (_) => Completer<int>());
    final List<StringBuffer> errBufs =
        List<StringBuffer>.generate(n, (_) => StringBuffer());

    bool isSuccess = false;
    final Stopwatch wall = Stopwatch()..start();

    try {
      // --- Create all FIFOs up front ---
      for (int i = 0; i < n; i++) {
        deleteQuietly(fifoPaths[i]);
        final ProcessResult mk = await Process.run('mkfifo', [fifoPaths[i]]);
        if (mk.exitCode != 0) {
          throw Exception('mkfifo failed for worker $i: ${mk.stderr}');
        }
      }

      // --- Spawn all workers (each blocks opening its FIFO) ---
      for (int i = 0; i < n; i++) {
        final (int, int) chunk = chunks[i];
        final Isolate iso = await Isolate.spawn(
          _workerMain,
          _WorkerConfig(
            workerId: i,
            fifoPath: fifoPaths[i],
            reply: fromWorkers.sendPort,
            vizName: vizName,
            audio: TransferableTypedData.fromList([audio]),
            sampleRate: sampleRate,
            chunkStart: chunk.$1,
            chunkEnd: chunk.$2,
            fps: fps,
            width: width,
            height: height,
            dampening: dampening,
            settings: settings,
            progressIntervalMs: progressIntervalMs,
          ),
        );
        isolates.add(iso);
      }

      // --- Start one ffmpeg per segment (releases each worker's open) ---
      for (int i = 0; i < n; i++) {
        final (int, int) chunk = chunks[i];
        final int chunkFrames = chunk.$2 - chunk.$1;
        final List<String> args =
            buildSegmentArgs(fifoPaths[i], segmentPaths[i], chunkFrames);
        final Process proc = await Process.start('ffmpeg', args);
        procs.add(proc);
        final int idx = i;
        unawaited(proc.exitCode.then((int code) {
          if (!exitC[idx].isCompleted) exitC[idx].complete(code);
        }));
        proc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(errBufs[idx].write);
      }

      onStatus?.call('Rendering & Baking Video (CPU x$n)...');

      // Wait for every worker to attach to its ffmpeg.
      await Future.wait(readyC.map((c) => c.future));
      if (firstError != null) {
        throw Exception('Worker failed to attach: $firstError');
      }

      // Wait for all chunks to finish, polling cancellation. A cancel
      // kills every ffmpeg; each worker's blocked write EPIPEs and it
      // exits on its own, completing its doneC via the error branch.
      final Future<void> allDone = Future.wait(doneC.map((c) => c.future));
      bool cancelledOut = false;
      while (true) {
        if (isCancelled()) {
          cancelledOut = true;
          break;
        }
        final Object? winner = await Future.any<Object?>([
          allDone.then((_) => 'done'),
          Future<Object?>.delayed(const Duration(milliseconds: 100)),
        ]);
        if (winner == 'done') break;
      }
      if (cancelledOut) {
        int framesSoFar = 0;
        for (final int d in perWorkerDone) {
          framesSoFar += d;
        }
        return SoftBakeResult(
          success: false, cancelled: true, framesWritten: framesSoFar,
          segmentPaths: const <String>[],
        );
      }

      if (firstError != null) {
        throw Exception('Worker failed: $firstError');
      }

      // All FIFOs closed by workers; wait for each ffmpeg to finalize
      // its segment.
      onStatus?.call('Finalizing Segments...');
      for (int i = 0; i < n; i++) {
        while (!exitC[i].isCompleted) {
          if (isCancelled()) {
            int framesSoFar = 0;
            for (final int d in perWorkerDone) {
              framesSoFar += d;
            }
            return SoftBakeResult(
              success: false, cancelled: true, framesWritten: framesSoFar,
              segmentPaths: const <String>[],
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final int code = await exitC[i].future;
        if (code != 0) {
          throw Exception(
              'Segment $i ffmpeg failed with code $code\n'
              '${errBufs[i].toString().trim()}');
        }
      }

      final double wallSec = wall.elapsedMicroseconds / 1e6;

      int framesRendered = 0;
      double weightedRender = 0, weightedWrite = 0;
      double sumReplay = 0, maxReplay = 0;
      double sumWarmup = 0, maxWarmup = 0;
      double sumBusySec = 0; // sum of per-worker (warmup + render+write) wall
      for (int i = 0; i < n; i++) {
        framesRendered += perWorkerFrames[i];
        weightedRender += perWorkerRenderMs[i];
        weightedWrite += perWorkerWriteMs[i];
        sumReplay += perWorkerReplayMs[i];
        if (perWorkerReplayMs[i] > maxReplay) {
          maxReplay = perWorkerReplayMs[i];
        }
        sumWarmup += perWorkerWarmupMs[i];
        if (perWorkerWarmupMs[i] > maxWarmup) {
          maxWarmup = perWorkerWarmupMs[i];
        }
        // Warm-up is genuine rasterization keeping a core busy, so it
        // counts toward busy time; only the scan-only suppressed
        // replay is excluded.
        sumBusySec += perWorkerWallSec[i] + perWorkerWarmupMs[i] / 1000.0;
      }
      final double invFrames =
          framesRendered > 0 ? 1.0 / framesRendered : 0.0;

      // Parallel efficiency: how much of (wall * workers) core-time
      // was actually spent on productive rasterization. sumBusySec is
      // each worker's real render+write wall PLUS its warm-up render
      // time (both are genuine rasterization; only the scan-only
      // suppressed replay is excluded). wallSec*n is the core-time
      // budget the pool occupied. 1.0 = every core busy the whole
      // wall; lower = idle cores (starvation or a straggler holding
      // the wall past when others finished).
      final double efficiency =
          (wallSec > 0 && n > 0) ? sumBusySec / (wallSec * n) : 0.0;

      final SoftBakeStats stats = SoftBakeStats(
        workerCount: n,
        framesRendered: framesRendered,
        wallSec: wallSec,
        avgRenderMs: weightedRender * invFrames,
        avgWriteWaitMs: weightedWrite * invFrames,
        avgReplayMs: n > 0 ? sumReplay / n : 0.0,
        maxReplayMs: maxReplay,
        avgWarmupMs: n > 0 ? sumWarmup / n : 0.0,
        maxWarmupMs: maxWarmup,
        parallelEfficiency: efficiency,
        perWorkerRenderMs: perWorkerRenderMs,
        perWorkerWriteMs: perWorkerWriteMs,
        perWorkerReplayMs: perWorkerReplayMs,
        perWorkerWarmupMs: perWorkerWarmupMs,
        perWorkerWallSec: perWorkerWallSec,
      );

      isSuccess = true;
      return SoftBakeResult(
        success: true, cancelled: false, framesWritten: framesRendered,
        segmentPaths: segmentPaths, stats: stats,
      );
    } catch (e) {
      return SoftBakeResult(
        success: false, cancelled: false, framesWritten: 0,
        segmentPaths: const <String>[], error: e.toString(),
      );
    } finally {
      // 1. Instantly kill any lingering FFmpeg processes (SIGKILL / 9)
      for (final Process p in procs) {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      // 2. Release any worker still blocked opening its FIFO
      for (int i = 0; i < n; i++) {
        if (!readyC[i].isCompleted) {
          try {
            final RandomAccessFile r =
                File(fifoPaths[i]).openSync(mode: FileMode.read);
            r.closeSync();
          } catch (_) {}
        }
      }
      // 3. Nuke all worker isolates instantly
      for (final Isolate iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
      // 4. Close ports
      fromWorkers.close();
      // 5. Cleanup FIFOs
      cleanupFifos();
      // 6. Cleanup Segments (Only if the bake failed/was cancelled)
      if (!isSuccess) {
        cleanupSegments();
      }
    }
  }
}