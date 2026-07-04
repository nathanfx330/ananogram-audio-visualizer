// ./lib/manifest.dart
//
// Per-export bake record. Written as a JSON sidecar next to each
// exported video (foo.mov -> foo.mov.json), recording everything
// needed to reproduce the bake exactly: source, visualization,
// format/codec, geometry, and the full WaveformSettings style block.
//
// The old export_manifest.json / merge.py schema is gone: the raw
// pixel pipeline never writes PNG frame sequences, so there is
// nothing for merge.py to merge. Reproducibility replaced it as
// this file's job.

import 'dart:convert';
import 'dart:io';

class ExportRecord {
  final String project;
  final String sourcePath;       // absolute path to the audio source
  final String outputPath;       // absolute path to the rendered video
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
  final DateTime createdUtc;

  ExportRecord({
    required this.project,
    required this.sourcePath,
    required this.outputPath,
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
    DateTime? createdUtc,
  }) : createdUtc = createdUtc ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ananogram_export': 2,
        'project': project,
        'created_utc': createdUtc.toIso8601String(),
        'source_path': sourcePath,
        'output_path': outputPath,
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