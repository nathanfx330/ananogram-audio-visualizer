// ./lib/playback.dart
//
// Subprocess audio playback with explicit output-device selection.
// v1 backend: paplay (PulseAudio / PipeWire via pipewire-pulse),
// fallback aplay (raw ALSA). Devices are enumerated by name so the
// user selects an actual sink, not a guessed index -- this replaces
// the PortAudio device-cycling workaround from app.py.
//
// Designed as an interface (AudioPlayback) so an ALSA FFI
// implementation can swap in later without touching main.dart.
//
// Streams f32le mono PCM to the child's stdin in chunks; volume is
// applied per-chunk in Dart. Stopping kills the process -- latency
// is at most one chunk (~92 ms at the default chunk size).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class PlaybackDevice {
  /// Backend-specific device identifier (Pulse sink name or ALSA
  /// device string). Null means backend default.
  final String? id;
  final String description;

  const PlaybackDevice({required this.id, required this.description});

  @override
  String toString() => description;
}

abstract class AudioPlayback {
  /// Human-readable backend name for the UI ("paplay", "aplay").
  String get backendName;

  Future<List<PlaybackDevice>> listDevices();

  /// Starts playback of [audio] (mono float32, [sampleRate] Hz) from
  /// [startSample], scaled by [volume], on [device] (null = default).
  /// Any playback already running is stopped first.
  Future<void> play(
    Float32List audio,
    int sampleRate, {
    int startSample = 0,
    double volume = 1.0,
    PlaybackDevice? device,
  });

  Future<void> stop();

  bool get isPlaying;
}

/// Picks the best available subprocess backend, or returns null if
/// neither paplay nor aplay exists (UI should show playback disabled;
/// export still works).
Future<AudioPlayback?> createPlayback() async {
  if (await _binaryExists('paplay')) return _SubprocessPlayback.paplay();
  if (await _binaryExists('aplay')) return _SubprocessPlayback.aplay();
  return null;
}

Future<bool> _binaryExists(String name) async {
  try {
    final ProcessResult r = await Process.run('which', [name]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

class _SubprocessPlayback implements AudioPlayback {
  @override
  final String backendName;

  final List<String> Function(int sampleRate, String? deviceId) _buildArgs;
  final Future<List<PlaybackDevice>> Function() _enumerate;

  Process? _proc;
  bool _playing = false;
  int _generation = 0; // invalidates stale feeder loops

  _SubprocessPlayback._(this.backendName, this._buildArgs, this._enumerate);

  factory _SubprocessPlayback.paplay() {
    return _SubprocessPlayback._(
      'paplay',
      (int rate, String? dev) => [
        '--raw',
        '--format=float32le',
        '--rate=$rate',
        '--channels=1',
        if (dev != null) '--device=$dev',
      ],
      _enumeratePulseSinks,
    );
  }

  factory _SubprocessPlayback.aplay() {
    return _SubprocessPlayback._(
      'aplay',
      (int rate, String? dev) => [
        '-t', 'raw',
        '-f', 'FLOAT_LE',
        '-r', '$rate',
        '-c', '1',
        '-q',
        if (dev != null) ...['-D', dev],
      ],
      _enumerateAlsaDevices,
    );
  }

  @override
  bool get isPlaying => _playing;

  @override
  Future<List<PlaybackDevice>> listDevices() => _enumerate();

  @override
  Future<void> play(
    Float32List audio,
    int sampleRate, {
    int startSample = 0,
    double volume = 1.0,
    PlaybackDevice? device,
  }) async {
    await stop();

    final int gen = ++_generation;
    final int start = startSample.clamp(0, audio.length);
    if (start >= audio.length) return;

    final Process proc = await Process.start(
      backendName == 'paplay' ? 'paplay' : 'aplay',
      _buildArgs(sampleRate, device?.id),
    );
    _proc = proc;
    _playing = true;

    // Drain stderr so the child never blocks on a full pipe.
    proc.stderr.drain<void>();

    // Feed PCM in chunks, applying volume per chunk. ~92 ms chunks:
    // stop latency is bounded by one chunk + sink buffer.
    const int chunkSamples = 4096;
    unawaited(() async {
      try {
        for (int i = start; i < audio.length; i += chunkSamples) {
          if (gen != _generation) return; // superseded by stop/play
          final int end = (i + chunkSamples <= audio.length)
              ? i + chunkSamples
              : audio.length;

          final Float32List chunk = Float32List(end - i);
          for (int j = 0; j < chunk.length; j++) {
            chunk[j] = audio[i + j] * volume;
          }
          proc.stdin.add(chunk.buffer.asUint8List(0, chunk.lengthInBytes));
          await proc.stdin.flush(); // backpressure pacing
        }
        if (gen == _generation) {
          await proc.stdin.close(); // let the sink drain, then exit
        }
      } catch (_) {
        // Broken pipe after kill() -- expected on stop; nothing to do.
      }
    }());

    // Mark not-playing when the process exits naturally (end of audio).
    unawaited(proc.exitCode.then((_) {
      if (gen == _generation) {
        _playing = false;
        _proc = null;
      }
    }));
  }

  @override
  Future<void> stop() async {
    _generation++;
    final Process? p = _proc;
    _proc = null;
    _playing = false;
    if (p != null) {
      try {
        p.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
  }

  // --- Device enumeration ---

  static Future<List<PlaybackDevice>> _enumeratePulseSinks() async {
    final List<PlaybackDevice> devices = [
      const PlaybackDevice(id: null, description: 'System Default'),
    ];
    try {
      final ProcessResult r =
          await Process.run('pactl', ['list', 'short', 'sinks']);
      if (r.exitCode == 0) {
        for (final String line in (r.stdout as String).split('\n')) {
          final List<String> parts = line.trim().split('\t');
          if (parts.length >= 2 && parts[1].isNotEmpty) {
            devices.add(PlaybackDevice(
              id: parts[1],
              description: _prettifySinkName(parts[1]),
            ));
          }
        }
      }
    } catch (_) {}
    return devices;
  }

  static String _prettifySinkName(String sink) {
    // alsa_output.pci-0000_00_1f.3.analog-stereo -> "analog-stereo (pci-0000_00_1f.3)"
    final List<String> segs = sink.split('.');
    if (segs.length >= 3 && segs.first.startsWith('alsa_output')) {
      return '${segs.last} (${segs.sublist(1, segs.length - 1).join('.')})';
    }
    return sink;
  }

  static Future<List<PlaybackDevice>> _enumerateAlsaDevices() async {
    final List<PlaybackDevice> devices = [
      const PlaybackDevice(id: null, description: 'System Default'),
    ];
    try {
      final ProcessResult r = await Process.run('aplay', ['-L']);
      if (r.exitCode == 0) {
        final List<String> lines = (r.stdout as String).split('\n');
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          if (line.isEmpty || line.startsWith(' ')) continue;
          final String name = line.trim();
          // Keep the useful ones; skip the plugin zoo.
          if (name == 'default' ||
              name.startsWith('hw:') ||
              name.startsWith('plughw:') ||
              name.startsWith('pulse') ||
              name.startsWith('pipewire')) {
            String desc = name;
            if (i + 1 < lines.length && lines[i + 1].startsWith(' ')) {
              desc = '$name — ${lines[i + 1].trim()}';
            }
            devices.add(PlaybackDevice(id: name, description: desc));
          }
        }
      }
    } catch (_) {}
    return devices;
  }
}