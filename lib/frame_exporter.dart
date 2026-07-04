// ./lib/frame_exporter.dart
//
// Deterministic offline video bake for Visualization plugins.
//
// Direct Pipe Pipeline with Native Backpressure:
// Render frame -> Raw RGBA -> FFmpeg stdin.
// Uses await proc.stdin.flush() to inherently pace the render loop to FFmpeg's
// encoding speed, preventing memory explosions without complex semaphores.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'manifest.dart';
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

class FrameExporter {
  static const String exportDir = 'export';

  // NVENC flags used by real exports.
  static const String _nvencPreset = 'p6';
  static const String _nvencCq = '18';

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

    final int frameCount = (durationSec * fps).ceil();
    final String project = ExportRecord.projectNameFromPath(sourcePath);

    final Directory dir = Directory(exportDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final bool useNvenc = allowNvenc && await _nvencWorks();
    final String h264Codec = useNvenc ? 'h264_nvenc' : 'libx264';
    final String h264Preset = useNvenc ? _nvencPreset : 'fast';

    String actualOutputPath = '$exportDir/$project.mov';
    String? mattePath;
    String videoCodec;

    // Stream RAW RGBA frames directly into stdin
    final List<String> args = [
      '-y',
      '-v', 'error',
      '-nostats',
      '-f', 'rawvideo',
      '-pix_fmt', 'rgba',
      '-s', '${width}x${height}',
      '-framerate', '$fps',
      '-i', '-', // Input 0: Stdin (Video)
      '-i', sourcePath, // Input 1: Source File (Audio)
    ];

    switch (format) {
      case VideoExportFormat.lumaMatte:
        actualOutputPath = actualOutputPath.replaceAll(RegExp(r'\.mov$'), '.mp4');
        mattePath = actualOutputPath.replaceAll('.mp4', '_matte.mp4');
        videoCodec = h264Codec;
        args.addAll([
          '-filter_complex',
          'color=c=black:s=${width}x${height}[bg]; [0:v]split=2[fg_color][fg_alpha]; [bg][fg_color]overlay=shortest=1,format=yuv420p[color]; [fg_alpha]alphaextract,format=yuv420p[matte]',
          '-map', '[color]', '-map', '1:a',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-c:a', 'aac', '-b:a', '320k', '-shortest',
          actualOutputPath,
          '-map', '[matte]',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-an', mattePath,
        ]);
        break;

      case VideoExportFormat.proresAlpha:
        actualOutputPath = actualOutputPath.replaceAll(RegExp(r'\.mp4$'), '.mov');
        videoCodec = 'prores_ks';
        args.addAll([
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
          '-filter_complex',
          'color=c=black:s=${width}x${height}[bg]; [bg][0:v]overlay=shortest=1,format=yuv420p[color]',
          '-map', '[color]', '-map', '1:a',
          '-c:v', h264Codec, '-preset', h264Preset,
          if (!useNvenc) ...['-crf', '18'],
          if (useNvenc) ...['-cq', _nvencCq],
          '-c:a', 'aac', '-b:a', '320k', '-shortest',
          actualOutputPath,
        ]);
        break;
    }

    final Process proc = await Process.start('ffmpeg', args);

    bool procDead = false;
    final Completer<int> exitC = Completer<int>();
    unawaited(proc.exitCode.then((int code) {
      procDead = true;
      exitC.complete(code);
    }));

    // Ignore broken pipe errors if FFmpeg closes stdin early
    unawaited(proc.stdin.done.catchError((_) {})); 

    final StringBuffer errBuf = StringBuffer();
    proc.stderr.transform(utf8.decoder).listen(errBuf.write);

    viz.reset();
    final VizCompositor compositor = VizCompositor(width: width, height: height);
    final double dt = 1.0 / fps;

    onStatus?.call('Rendering & Baking Video...');

    int renderedFrames = 0;

    try {
      for (int i = 0; i < frameCount; i++) {
        if (cancelToken?.isCancelled ?? false) {
          proc.kill(ProcessSignal.sigterm);
          return ExportResult(success: false, cancelled: true, framesWritten: renderedFrames, outputPath: actualOutputPath);
        }
        if (procDead) throw Exception('FFmpeg died during encode (at frame $i)\n${errBuf.toString().trim()}');

        final VizContext ctx = VizContext(
          audio: audio, sampleRate: sampleRate, t: i / fps, frameIndex: i,
          dt: dt, width: width, height: height, dampening: dampening, settings: settings,
        );

        // Advance asynchronously using the isExport flag to prevent the 
        // infinitely nested DisplayList VRAM leak.
        final ui.Image frame = await compositor.advanceAsync(viz, ctx, isExport: true);

        // Extract raw RGBA bytes natively (Fast)
        final ByteData? rawBytes = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
        
        // Dispose the frame instantly to free the single isolated GPU texture.
        frame.dispose();

        if (rawBytes == null) throw Exception('Failed to extract raw pixels at frame $i.');

        final Uint8List bytes = rawBytes.buffer.asUint8List(rawBytes.offsetInBytes, rawBytes.lengthInBytes);

        // Feed FFmpeg directly via Stdin
        proc.stdin.add(bytes);
        
        // OS NATIVE BACKPRESSURE:
        // This inherently waits if FFmpeg is overwhelmed and the OS pipe is full.
        // It prevents RAM explosions effortlessly.
        await proc.stdin.flush(); 

        renderedFrames++;
        onProgress?.call(renderedFrames, frameCount);

        // Force a micro-pause so the UI progress bar actually paints at 60fps!
        await Future.delayed(const Duration(milliseconds: 1));
      }

      // Close the pipe to tell FFmpeg we are done sending frames
      await proc.stdin.close();

      onStatus?.call('Finalizing File...');

      // Wait for FFmpeg to finish encoding the trailing frames
      while (!exitC.isCompleted) {
        if (cancelToken?.isCancelled ?? false) {
          proc.kill(ProcessSignal.sigterm);
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
      proc.kill(ProcessSignal.sigterm);
      return ExportResult(
        success: false, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath,
        error: e.toString(),
      );
    } finally {
      compositor.dispose();
    }

    // Save Manifest sidecar
    final Map<String, dynamic> style = settings.toJson();
    if (mattePath != null) style['matte_path'] = File(mattePath).absolute.path;
    
    final ExportRecord record = ExportRecord(
      project: project, sourcePath: File(sourcePath).absolute.path,
      outputPath: File(actualOutputPath).absolute.path, visualization: viz.name,
      format: format.name, videoCodec: videoCodec, nvencUsed: videoCodec == 'h264_nvenc',
      fps: fps, frameCount: renderedFrames, width: width, height: height,
      dampening: dampening, audioDurationSec: durationSec, style: style,
    );
    record.writeSidecar();

    return ExportResult(success: true, cancelled: false, framesWritten: renderedFrames, outputPath: actualOutputPath);
  }
}