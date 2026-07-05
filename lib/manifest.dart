// ./lib/manifest.dart
//
// Per-export bake record. Written as a JSON sidecar next to each
// exported video (foo.mov -> foo.mov.json), recording everything
// needed to reproduce the bake exactly: source, visualization,
// format/codec, geometry, and the full WaveformSettings style block.
//
// Also records whole-run pipeline performance (ExportPerformance):
// the per-stage numbers the exporter prints to the terminal during
// debug runs die in stdout on a compiled binary, so the sidecar is
// where a release build reports its true speed vs realtime.
//
// The old export_manifest.json / merge.py schema is gone: the raw
// pixel pipeline never writes PNG frame sequences, so there is
// nothing for merge.py to merge. Reproducibility replaced it as
// this file's job.

import 'dart:convert';
import 'dart:io';

/// Whole-run export pipeline performance. Same stages as the
/// terminal timing report, aggregated across every frame instead of
/// per-60-frame windows. All averages are per-frame milliseconds.
///
/// Stage semantics (matching frame_exporter.dart instrumentation):
///   render   -- advanceAsync: GPU rasterization round trip
///   readback -- residual toByteData await AFTER overlapping with
///               the next render (near zero when fully hidden)
///   write_wait -- backpressure: waiting for a writer-isolate slot
///               (FFmpeg encode falling behind shows up here)
class ExportPerformance {
  final double exportWallSec;    // total wall clock, first frame to last ack
  final double exportFps;        // frames rendered / wall sec
  final double realtimeFactor;   // exportFps / target fps (>1 = faster than realtime)
  final double avgRenderMs;
  final double avgReadbackMs;
  final double avgWriteWaitMs;

  const ExportPerformance({
    required this.exportWallSec,
    required this.exportFps,
    required this.realtimeFactor,
    required this.avgRenderMs,
    required this.avgReadbackMs,
    required this.avgWriteWaitMs,
  });

  static double _r(double v, [int places = 2]) {
    final double f = places == 1 ? 10.0 : (places == 2 ? 100.0 : 1000.0);
    return (v * f).roundToDouble() / f;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'export_wall_sec': _r(exportWallSec),
        'export_fps': _r(exportFps, 1),
        'realtime_factor': _r(realtimeFactor),
        'avg_render_ms': _r(avgRenderMs, 1),
        'avg_readback_ms': _r(avgReadbackMs, 1),
        'avg_write_wait_ms': _r(avgWriteWaitMs, 1),
      };
}

class ExportRecord {
  final String project;
  final String sourcePath;       // absolute path to the audio source
  final String outputPath;       // absolute path to the rendered video
  final String? mattePath;       // absolute path to the matte pass
                                 // (lumaMatte format only, else null)
  final String visualization;    // Visualization.name
  final String format;           // VideoExportFormat name
  final String videoCodec;       // e.g. h264_nvenc / libx264 / prores_ks
  final bool nvencUsed;
  final int fps;
  final int frameCount;
  final int width;
  final int height;
  final double dampening;
  final double audioDurationSec;
  final Map<String, dynamic> style; // WaveformSettings.toJson()
  final ExportPerformance? performance; // null if export never measured
  final DateTime createdUtc;

  ExportRecord({
    required this.project,
    required this.sourcePath,
    required this.outputPath,
    this.mattePath,
    required this.visualization,
    required this.format,
    required this.videoCodec,
    required this.nvencUsed,
    required this.fps,
    required this.frameCount,
    required this.width,
    required this.height,
    required this.dampening,
    required this.audioDurationSec,
    required this.style,
    this.performance,
    DateTime? createdUtc,
  }) : createdUtc = createdUtc ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ananogram_export': 3,
        'project': project,
        'created_utc': createdUtc.toIso8601String(),
        'source_path': sourcePath,
        'output_path': outputPath,
        if (mattePath != null) 'matte_path': mattePath,
        'visualization': visualization,
        'format': format,
        'video_codec': videoCodec,
        'nvenc_used': nvencUsed,
        'fps': fps,
        'frame_count': frameCount,
        'width': width,
        'height': height,
        'dampening': dampening,
        'audio_duration_sec': audioDurationSec,
        'style': style,
        if (performance != null) 'performance': performance!.toJson(),
      };

  /// Writes the sidecar next to the rendered video:
  /// export/foo.mov -> export/foo.mov.json. Best-effort by design --
  /// a failed sidecar write must never fail a successful bake, so
  /// callers should treat a false return as a warning, not an error.
  bool writeSidecar() {
    try {
      final String jsonText =
          const JsonEncoder.withIndent('  ').convert(toJson());
      File('$outputPath.json').writeAsStringSync(jsonText);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sanitizes a source-file path into a project name: basename,
  /// extension stripped, every char outside [a-zA-Z0-9-_] replaced
  /// with underscore. Same rule frame_exporter.dart applies to the
  /// output filename, kept here as the single canonical definition.
  static String projectNameFromPath(String sourcePath) {
    String stem = sourcePath.split(Platform.pathSeparator).last;
    stem = stem.split('/').last;
    final int dot = stem.lastIndexOf('.');
    if (dot > 0) stem = stem.substring(0, dot);
    final StringBuffer out = StringBuffer();
    for (final int code in stem.codeUnits) {
      final bool ok = (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x41 && code <= 0x5A) ||             // A-Z
          (code >= 0x61 && code <= 0x7A) ||             // a-z
          code == 0x2D ||                               // -
          code == 0x5F;                                 // _
      out.writeCharCode(ok ? code : 0x5F);
    }
    return out.toString();
  }
}