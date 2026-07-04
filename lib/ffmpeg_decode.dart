// ./lib/ffmpeg_decode.dart
//
// Decodes any ffmpeg-readable audio file (MP3, FLAC, OGG, M4A, ...)
// to normalized mono Float32 at the target rate by streaming raw
// f32le PCM from an ffmpeg subprocess over stdout. No temp files,
// no pub dependencies -- ffmpeg is a system binary requirement,
// consistent with merge.py.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class FfmpegDecodeResult {
  final Float32List data;      // mono, normalized to peak 1.0
  final int sampleRate;
  final double durationSec;

  const FfmpegDecodeResult({
    required this.data,
    required this.sampleRate,
    required this.durationSec,
  });
}

class FfmpegDecodeException implements Exception {
  final String message;
  const FfmpegDecodeException(this.message);

  @override
  String toString() => 'FfmpegDecodeException: $message';
}

class FfmpegDecoder {
  /// Returns true if ffmpeg is available on PATH.
  static Future<bool> isAvailable() async {
    try {
      final ProcessResult r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Decodes [path] to mono float32 at [targetRate] Hz, peak-normalized.
  ///
  /// Streams PCM from ffmpeg stdout chunk-by-chunk rather than
  /// buffering the whole process output, so memory overhead beyond
  /// the final sample buffer is one accumulation list of chunks.
  ///
  /// Throws [FfmpegDecodeException] if ffmpeg is missing, exits
  /// nonzero, or produces no audio.
  static Future<FfmpegDecodeResult> decodeFile(
    String path, {
    int targetRate = 44100,
  }) async {
    if (!await isAvailable()) {
      throw const FfmpegDecodeException(
          'ffmpeg not found on PATH (required for non-WAV decoding).');
    }

    final Process proc = await Process.start('ffmpeg', [
      '-v', 'error',
      '-i', path,
      '-f', 'f32le',
      '-ac', '1',
      '-ar', '$targetRate',
      '-',
    ]);

    // Collect stdout chunks and stderr text concurrently.
    final List<Uint8List> chunks = <Uint8List>[];
    int totalBytes = 0;

    final Future<void> stdoutDone = proc.stdout.forEach((List<int> chunk) {
      final Uint8List u = chunk is Uint8List
          ? chunk
          : Uint8List.fromList(chunk);
      chunks.add(u);
      totalBytes += u.length;
    });

    final StringBuffer errBuf = StringBuffer();
    final Future<void> stderrDone = proc.stderr.forEach((List<int> chunk) {
      errBuf.write(String.fromCharCodes(chunk));
    });

    final int exitCode = await proc.exitCode;
    await stdoutDone;
    await stderrDone;

    if (exitCode != 0) {
      throw FfmpegDecodeException(
          'ffmpeg exited $exitCode: ${errBuf.toString().trim()}');
    }
    if (totalBytes < 4) {
      throw const FfmpegDecodeException('ffmpeg produced no audio data.');
    }

    // Assemble contiguous byte buffer, truncated to whole float32s.
    final int usableBytes = totalBytes & ~3;
    final Uint8List raw = Uint8List(usableBytes);
    int offset = 0;
    for (final Uint8List c in chunks) {
      final int take = (offset + c.length <= usableBytes)
          ? c.length
          : usableBytes - offset;
      if (take <= 0) break;
      raw.setRange(offset, offset + take, c);
      offset += take;
    }

    // View as float32. asByteData guards alignment; Uint8List fresh
    // allocations are 8-byte aligned in Dart, so a direct view is safe.
    final Float32List data =
        raw.buffer.asFloat32List(0, usableBytes ~/ 4);

    // Peak normalize (matches WavDecoder / app.py behavior).
    double peak = 0.0;
    for (int i = 0; i < data.length; i++) {
      final double a = data[i].abs();
      if (a > peak) peak = a;
    }
    if (peak > 0.0) {
      final double inv = 1.0 / peak;
      for (int i = 0; i < data.length; i++) {
        data[i] *= inv;
      }
    }

    return FfmpegDecodeResult(
      data: data,
      sampleRate: targetRate,
      durationSec: data.length / targetRate,
    );
  }

  /// Optional: probe duration in seconds via ffprobe. Returns null if
  /// ffprobe is unavailable or the probe fails. Not required by the
  /// decode path -- useful for pre-decode progress estimation.
  static Future<double?> probeDurationSec(String path) async {
    try {
      final ProcessResult r = await Process.run('ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        path,
      ]);
      if (r.exitCode != 0) return null;
      return double.tryParse((r.stdout as String).trim());
    } catch (_) {
      return null;
    }
  }
}