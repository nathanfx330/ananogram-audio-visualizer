// ./lib/main.dart
//
// Ananogram (Flutter port) -- app shell, live visualizer platform,
// transport, device selection, settings, and export UI. Linux
// desktop target.
//
// Launch from the project root: exports land in export/ relative to
// the working directory, each with a .json bake-record sidecar.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'ffmpeg_decode.dart';
import 'frame_exporter.dart';
import 'playback.dart';
import 'visualization.dart';
import 'visualizer_painter.dart';
import 'wav_decoder.dart';

const int kTargetSampleRate = 44100;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  
  WindowOptions windowOptions = const WindowOptions(
    title: 'Ananogram',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const AnanogramApp());
}

class AnanogramApp extends StatelessWidget {
  const AnanogramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ananogram',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF32FF32),
          secondary: Color(0xFF1EA01E),
          surface: Color(0xFF1A1A1A),
        ),
      ),
      home: const AnanogramHome(),
    );
  }
}

/// Phosphor color presets: outer / mid / core stroke triples.
class _PhosphorPreset {
  final String name;
  final Color outer;
  final Color mid;
  final Color core;
  const _PhosphorPreset(this.name, this.outer, this.mid, this.core);
}

const List<_PhosphorPreset> _phosphorPresets = [
  _PhosphorPreset('Green', Color(0xFF1EA01E), Color(0xFF32FF32), Color(0xFFC8FFC8)),
  _PhosphorPreset('Amber', Color(0xFFA06414), Color(0xFFFFB428), Color(0xFFFFE6B4)),
  _PhosphorPreset('Cyan', Color(0xFF14828C), Color(0xFF28DCFF), Color(0xFFC8F5FF)),
  _PhosphorPreset('Magenta', Color(0xFF8C1478), Color(0xFFFF3CDC), Color(0xFFFFC8F0)),
  _PhosphorPreset('White', Color(0xFF787878), Color(0xFFE6E6E6), Color(0xFFFFFFFF)),
  _PhosphorPreset('Forensic (Dark Ink)', Color(0xFFDDDDDD), Color(0xFF888888), Color(0xFF222222)),
];

// Helper classes for export settings dropdowns
class _Resolution {
  final String name;
  final int width;
  final int height;
  const _Resolution(this.name, this.width, this.height);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _Resolution && width == other.width && height == other.height;

  @override
  int get hashCode => width.hashCode ^ height.hashCode;
}

const List<_Resolution> _resolutions = [
  _Resolution('720p (HD)', 1280, 720),
  _Resolution('1080p (FHD)', 1920, 1080),
  _Resolution('1440p (QHD)', 2560, 1440),
  _Resolution('2160p (4K)', 3840, 2160),
];

class AnanogramHome extends StatefulWidget {
  const AnanogramHome({super.key});

  @override
  State<AnanogramHome> createState() => _AnanogramHomeState();
}

class _AnanogramHomeState extends State<AnanogramHome> with SingleTickerProviderStateMixin, WindowListener {
  // --- Audio state ---
  Float32List? _audio;
  int _sampleRate = kTargetSampleRate;
  double _totalTime = 0.0;
  String? _loadedPath;
  bool _loading = false;

  // --- Transport state (mirrors app.py time model) ---
  bool _playing = false;
  double _currentTime = 0.0;
  double _playStartPos = 0.0;
  DateTime _playStartWall = DateTime.now();
  bool _scrubbing = false;
  
  // Tracks how long the audio has been paused to let the trail fade out
  double _timeSincePaused = 0.0;

  // --- Settings ---
  double _volume = 1.0;
  double _dampening = 1.0;
  final WaveformSettings _settings = WaveformSettings.defaults();

  // --- Export Settings ---
  int _exportFps = 30;
  _Resolution _exportResolution = _resolutions[1]; // Default 1080p
  VideoExportFormat _exportFormat = VideoExportFormat.lumaMatte; // Default Format
  bool _allowNvenc = false; // GPU encoding opt-in; CPU is the known-good path
  int _workerCount = math.max(1, (math.max(1, Platform.numberOfProcessors ~/ 2) * 0.75).floor()); // 75% of physical cores
  bool _unlockMaxWorkers = false; // Lock out the 100% core saturation by default

  // --- Visualization platform ---
  late final List<Visualization> _visualizations;
  late Visualization _viz;

  // --- Playback backend ---
  AudioPlayback? _playback;
  List<PlaybackDevice> _devices = const [];
  PlaybackDevice? _selectedDevice;

  // --- Live view ---
  late final Ticker _ticker;
  VizCompositor? _compositor;
  int _frameCounter = 0;
  Duration _lastElapsed = Duration.zero;
  int _viewW = 0;
  int _viewH = 0;

  // Live-preview render throttle. The Ticker fires at monitor vsync
  // (60/120/144 Hz), but the preview is a monitor, not the
  // deliverable -- ~30fps of distinct frames is imperceptible for a
  // scope. Capping the LIVE render rate caps how fast orphaned
  // GC-owned textures are minted during playback, which (with the
  // continuous-time floor decay) no longer reach a fixed point and so
  // must not be produced every vsync. Export is unaffected: it never
  // touches this path.
  //
  // TWO SUBTLETIES, both learned the hard way:
  //
  //  1. The dt handed to VizContext must be the time since the last
  //     RENDERED frame, not the per-tick dt. Every temporal recurrence
  //     (trail decay, AGC, plugin smoothing) is pow(x, 30*dt) -- feed
  //     it the 16.7ms tick dt while rendering every ~33ms and all time
  //     constants run at half speed: trails linger, smoothing drags,
  //     and the preview no longer matches export. _sinceLiveRender IS
  //     that accumulated value; it is captured as renderDt before the
  //     reset and passed to the context.
  //
  //  2. The threshold sits BELOW the exact 2-tick sum, not at it.
  //     1/30 vs two 60Hz ticks is a float-equality knife edge: renders
  //     alternate between landing on tick 2 (33ms) and slipping to
  //     tick 3 (50ms), and the phase wanders -- textbook judder, more
  //     visible than a clean constant 30fps. 0.030s is safely under
  //     2/60 and over 1/60, so 60Hz locks to every 2nd vsync (~30fps),
  //     120Hz to every 4th, 144Hz to every 5th (~28.8fps). Constant
  //     cadence at the cost of the cap being "about 30" instead of
  //     exactly 30 -- the right trade for a preview.
  //
  // A forced render (viz switch, scrub, settings change) zeroes
  // _timeSincePaused, which does NOT reset this accumulator, so it
  // lands on the next slot within at most one interval -- visually
  // immediate.
  static const double _liveRenderIntervalSec = 0.030;
  double _sinceLiveRender = 0.0;

  // --- Export ---
  bool _exporting = false;
  int _exportDone = 0;
  int _exportTotal = 0;
  ExportCancelToken? _cancelToken;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Intercept the close event so we can kill FFmpeg cleanly
    windowManager.setPreventClose(true);

    _visualizations = buildVisualizations();
    _viz = _visualizations.first;
    _ticker = createTicker(_onTick)..start();
    _initPlayback();
  }

  @override
  void onWindowClose() async {
    if (_exporting && _cancelToken != null) {
      setState(() {
        _statusMessage = 'Emergency teardown... killing encoders before exit.';
      });
      _cancelToken!.cancel();
      // Wait half a second to let the finally block slaughter the FFmpeg ghosts
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await windowManager.destroy();
  }

  Future<void> _initPlayback() async {
    final AudioPlayback? pb = await createPlayback();
    final List<PlaybackDevice> devs = pb == null ? const [] : await pb.listDevices();
    if (!mounted) return;
    setState(() {
      _playback = pb;
      _devices = devs;
      _selectedDevice = devs.isNotEmpty ? devs.first : null;
      if (pb == null) {
        _statusMessage = 'No playback backend (paplay/aplay not found). Export still works.';
      }
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _ticker.dispose();
    _playback?.stop();
    _compositor?.dispose();
    super.dispose();
  }

  // ---------------- TIME + TICK ----------------

  void _onTick(Duration elapsed) {
    final double dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;

    if (_audio == null || _exporting) return;

    bool wantsRender = false;

    if (_playing) {
      _timeSincePaused = 0.0;
      wantsRender = true;

      final double wallElapsed = DateTime.now().difference(_playStartWall).inMicroseconds / 1e6;
      _currentTime = _playStartPos + wallElapsed;
      if (_currentTime >= _totalTime) {
        _currentTime = _totalTime;
        _playing = false;
        _playback?.stop();
      }
    } else {
      // Paused: keep rendering until the trail fades, then the Ticker
      // goes fully idle (no advance, no setState) so the GC can sweep
      // the orphaned live textures.
      _timeSincePaused += dt;
      if (_timeSincePaused < 2.0) {
        wantsRender = true;
      }
    }

    // Throttle gate (see the comment at _liveRenderIntervalSec).
    _sinceLiveRender += dt;
    if (wantsRender && _sinceLiveRender < _liveRenderIntervalSec) {
      return;
    }
    
    final double renderDt = _sinceLiveRender;
    _sinceLiveRender = 0.0;

    if (wantsRender && _viewW > 0 && _viewH > 0) {
      _compositor ??= VizCompositor(width: _viewW, height: _viewH);
      final VizContext ctx = VizContext(
        audio: _audio!,
        sampleRate: _sampleRate,
        t: _currentTime,
        frameIndex: _frameCounter,
        dt: renderDt,
        width: _viewW,
        height: _viewH,
        dampening: _dampening,
        settings: _settings,
      );

      _compositor!.advance(_viz, ctx);
      _frameCounter++;

      setState(() {});
    }
  }

  void _onViewSized(int w, int h) {
    if (w != _viewW || h != _viewH) {
      _viewW = w;
      _viewH = h;
      _compositor?.dispose();
      _compositor = null;
    }
  }

  void _selectViz(Visualization v) {
    setState(() {
      _viz = v;
      _viz.reset();
      _compositor?.clear();
      _timeSincePaused = 0.0; // Force a render to show the new viz
    });
  }

  // ---------------- LOAD ----------------

  Future<String?> _pickFile() async {
    for (final List<String> attempt in [
      ['zenity', '--file-selection', '--title=Select Audio File', '--file-filter=Audio | *.wav *.mp3 *.flac *.ogg *.m4a'],
      ['kdialog', '--getopenfilename', '.', 'Audio (*.wav *.mp3)'],
    ]) {
      try {
        final ProcessResult r = await Process.run(attempt.first, attempt.sublist(1));
        if (r.exitCode == 0) {
          final String path = (r.stdout as String).trim();
          if (path.isNotEmpty) return path;
        }
        return null;
      } catch (_) {
        continue;
      }
    }
    if (!mounted) return null;
    final TextEditingController ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter audio file path'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '/path/to/audio.wav'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Load')),
        ],
      ),
    );
  }

  Future<void> _loadAudio() async {
    final String? path = await _pickFile();
    if (path == null || path.isEmpty) return;

    await _stopPlayback();
    setState(() {
      _loading = true;
      _statusMessage = 'Loading ${path.split('/').last}...';
    });

    try {
      Float32List data;
      final String ext = path.toLowerCase();
      if (ext.endsWith('.wav')) {
        final WavDecodeResult r = await Isolate.run(() => WavDecoder.decodeFile(path, targetRate: kTargetSampleRate));
        data = r.data;
      } else {
        final FfmpegDecodeResult r = await FfmpegDecoder.decodeFile(path, targetRate: kTargetSampleRate);
        data = r.data;
      }

      if (!mounted) return;
      setState(() {
        _audio = data;
        _sampleRate = kTargetSampleRate;
        _totalTime = data.length / kTargetSampleRate;
        _loadedPath = path;
        _currentTime = 0.0;
        _playing = false;
        _timeSincePaused = 0.0; // Force a render to show the loaded state
        for (final Visualization v in _visualizations) {
          v.reset();
        }
        _compositor?.clear();
        _loading = false;
        _statusMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusMessage = 'Load failed: $e';
      });
    }
  }

  // ---------------- TRANSPORT ----------------

  Future<void> _startPlayback() async {
    final Float32List? audio = _audio;
    if (audio == null || _playback == null) return;
    _playStartPos = _currentTime;
    _playStartWall = DateTime.now();
    await _playback!.play(
      audio,
      _sampleRate,
      startSample: (_currentTime * _sampleRate).toInt(),
      volume: _volume,
      device: _selectedDevice,
    );
    setState(() => _playing = true);
  }

  Future<void> _stopPlayback() async {
    if (_playing) {
      _currentTime = _playStartPos + DateTime.now().difference(_playStartWall).inMicroseconds / 1e6;
      if (_currentTime > _totalTime) _currentTime = _totalTime;
    }
    _playing = false;
    _timeSincePaused = 0.0; // Keep rendering briefly so the trail fades out
    await _playback?.stop();
    if (mounted) setState(() {});
  }

  Future<void> _togglePlay() async {
    if (_audio == null || _exporting) return;
    if (_playing) {
      await _stopPlayback();
    } else {
      await _startPlayback();
    }
  }

  void _scrubTo(double fraction) {
    if (_audio == null || _exporting) return;
    if (_playing) _stopPlayback();
    setState(() {
      _scrubbing = true;
      _currentTime = (fraction.clamp(0.0, 1.0)) * _totalTime;
      _timeSincePaused = 0.0; // Render the new scrubbed position
    });
  }

  // ---------------- EXPORT ----------------

  Future<void> _export() async {
    final Float32List? audio = _audio;
    final String? path = _loadedPath;
    if (audio == null || path == null || _exporting) return;

    await _stopPlayback();
    final ExportCancelToken token = ExportCancelToken();

    setState(() {
      _exporting = true;
      _exportDone = 0;
      _exportTotal = (_totalTime * _exportFps).ceil();
      _cancelToken = token;
      _statusMessage = 'Starting export...';
    });

    final ExportResult result = await FrameExporter.export(
      viz: _viz,
      audio: audio,
      sampleRate: _sampleRate,
      durationSec: _totalTime,
      sourcePath: path,
      dampening: _dampening,
      settings: _settings,
      fps: _exportFps,
      width: _exportResolution.width,
      height: _exportResolution.height,
      format: _exportFormat,
      workerCount: _workerCount,
      allowNvenc: _allowNvenc,
      cancelToken: token,
      onStatus: (status) {
        if (mounted) {
          setState(() {
            _statusMessage = status;
          });
        }
      },
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _exportDone = done;
            _exportTotal = total;
          });
        }
      },
    );

    if (!mounted) return;

    setState(() {
      _exporting = false;
      _cancelToken = null;
      _viz.reset();
      _compositor?.clear();

      if (result.success) {
        _statusMessage = '✅ Export complete: ${Directory(result.outputPath).absolute.path}';
      } else if (result.cancelled) {
        _statusMessage = 'Export cancelled at frame ${result.framesWritten}.';
      } else {
        _statusMessage = '❌ Export failed: ${result.error}';
      }
    });
  }

  // ---------------- SETTINGS DIALOG ----------------

  bool _presetMatches(_PhosphorPreset p) =>
      _settings.outerColor == p.outer.value &&
      _settings.midColor == p.mid.value &&
      _settings.coreColor == p.core.value;

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void both(VoidCallback fn) {
            setLocal(fn);
            setState(() {});
          }

          int logicalThreads = Platform.numberOfProcessors;
          int physicalCores = math.max(1, logicalThreads ~/ 2);
          int recommendedMax = math.max(1, (physicalCores * 0.75).floor());
          int currentMax = _unlockMaxWorkers ? logicalThreads : recommendedMax;

          // Safety clamp in case properties drifted
          if (_workerCount > currentMax) {
            _workerCount = currentMax;
          }

          return AlertDialog(
            title: const Text('Visualizer & Audio Settings'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- Export Settings ---
                    const Text('Export Format', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Video Codec: '),
                        const Spacer(),
                        DropdownButton<VideoExportFormat>(
                          value: _exportFormat,
                          isDense: true,
                          items: const [
                            DropdownMenuItem(value: VideoExportFormat.lumaMatte, child: Text('H.264 Luma Matte (Small)')),
                            DropdownMenuItem(value: VideoExportFormat.h264SolidBlack, child: Text('H.264 Solid Black (Small)')),
                            DropdownMenuItem(value: VideoExportFormat.proresAlpha, child: Text('ProRes 4444 Alpha (Huge)')),
                          ],
                          onChanged: (v) => both(() {
                            if (v != null) _exportFormat = v;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Resolution: '),
                        const Spacer(),
                        DropdownButton<_Resolution>(
                          value: _exportResolution,
                          isDense: true,
                          items: _resolutions.map((r) {
                            return DropdownMenuItem(value: r, child: Text(r.name));
                          }).toList(),
                          onChanged: (v) => both(() {
                            if (v != null) _exportResolution = v;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Framerate (FPS): '),
                        const Spacer(),
                        DropdownButton<int>(
                          value: _exportFps,
                          isDense: true,
                          items: const [
                            DropdownMenuItem(value: 24, child: Text('24 (Cinematic)')),
                            DropdownMenuItem(value: 30, child: Text('30 (Standard)')),
                            DropdownMenuItem(value: 60, child: Text('60 (Smooth)')),
                          ],
                          onChanged: (v) => both(() {
                            if (v != null) _exportFps = v;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('CPU Render Workers: $_workerCount (Max $currentMax)'),
                    Slider(
                      value: _workerCount.toDouble().clamp(1.0, currentMax.toDouble()),
                      min: 1,
                      max: currentMax.toDouble(),
                      divisions: currentMax > 1 ? currentMax - 1 : 1,
                      label: '$_workerCount',
                      onChanged: (v) => both(() => _workerCount = v.round()),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Unlock max workers (Not Recommended)'),
                      subtitle: const Text(
                        'Using 100% of cores can starve the OS and FFmpeg, causing stutters and slowing down the render.',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _unlockMaxWorkers,
                      onChanged: (v) => both(() {
                        _unlockMaxWorkers = v ?? false;
                        if (!_unlockMaxWorkers && _workerCount > recommendedMax) {
                          _workerCount = recommendedMax;
                        }
                      }),
                    ),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('GPU acceleration (NVENC)'),
                      subtitle: const Text(
                        'Experimental. If exports stall, leave this off — CPU encoding always works.',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _allowNvenc,
                      onChanged: (v) => both(() => _allowNvenc = v ?? false),
                    ),
                    const Divider(height: 24),

                    // --- Audio ---
                    const Text('Playback', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Text('Master Volume: ${(_volume * 100).round()}%'),
                    Slider(
                      value: _volume,
                      onChanged: (v) => both(() => _volume = v),
                      onChangeEnd: (v) async {
                        if (_playing) {
                          await _stopPlayback();
                          await _startPlayback();
                        }
                      },
                    ),
                    const Divider(height: 24),

                    // --- Waveform shape ---
                    const Text('Plugin Behavior', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Text('Waveform Amplitude: ${(_dampening / 3.0 * 100).round()}%'),
                    Slider(
                      value: _dampening,
                      max: 3.0,
                      onChanged: (v) => both(() => _dampening = v),
                    ),

                    Text('Time Window: ${(_settings.windowDuration * 1000).round()} ms'),
                    Slider(
                      value: _settings.windowDuration,
                      min: 0.01,
                      max: 0.50,
                      onChanged: (v) => both(() => _settings.windowDuration = v),
                    ),
                    const Divider(height: 24),

                    // --- Glow / trail ---
                    const Text('Style & Glow', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Background Color: '),
                        const Spacer(),
                        DropdownButton<int>(
                          value: _settings.backgroundColor,
                          isDense: true,
                          items: const [
                            DropdownMenuItem(value: 0xFF000000, child: Text('Black')),
                            DropdownMenuItem(value: 0xFFFFFFFF, child: Text('White')),
                          ],
                          onChanged: (v) => both(() {
                            if (v != null) _settings.backgroundColor = v;
                            _timeSincePaused = 0.0; // Force render to show new BG
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Trail Persistence: ${(_settings.trailRetention * 100).round()}%'),
                    Slider(
                      value: _settings.trailRetention,
                      max: 0.98,
                      onChanged: (v) => both(() {
                        _settings.trailRetention = v;
                        _timeSincePaused = 0.0; // Force render to show trail length
                      }),
                    ),

                    Text('Glow Blur: ${_settings.glowBlurSigma.toStringAsFixed(1)} px'),
                    Slider(
                      value: _settings.glowBlurSigma,
                      max: 8.0,
                      onChanged: (v) => both(() {
                        _settings.glowBlurSigma = v;
                        _timeSincePaused = 0.0; // Force render to show blur
                      }),
                    ),

                    Text('Stroke Width: ${(_settings.strokeScale * 100).round()}%'),
                    Slider(
                      value: _settings.strokeScale,
                      min: 0.25,
                      max: 10.0, // Increased to 10.0 (1000%)
                      onChanged: (v) => both(() {
                        _settings.strokeScale = v;
                        _timeSincePaused = 0.0; // Force render to show width
                      }),
                    ),
                    const Divider(height: 24),

                    // --- Phosphor color ---
                    const Text('Phosphor Palette', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ..._phosphorPresets.map((p) {
                          final bool active = _presetMatches(p);
                          return ChoiceChip(
                            label: Text(p.name),
                            selected: active,
                            avatar: CircleAvatar(backgroundColor: p.mid, radius: 8),
                            onSelected: (_) => both(() {
                              _settings.outerColor = p.outer.value;
                              _settings.midColor = p.mid.value;
                              _settings.coreColor = p.core.value;
                              _timeSincePaused = 0.0; // Force render to show color
                            }),
                          );
                        }),
                        ActionChip(
                          label: const Text('Custom...'),
                          avatar: const Icon(Icons.color_lens, size: 16),
                          onPressed: () async {
                            final int origOuter = _settings.outerColor;
                            final int origMid = _settings.midColor;
                            final int origCore = _settings.coreColor;

                            final result = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => _CustomColorPickerDialog(
                                outer: _settings.outerColor,
                                mid: _settings.midColor,
                                core: _settings.coreColor,
                                onChanged: (o, m, c) {
                                  both(() {
                                    _settings.outerColor = o;
                                    _settings.midColor = m;
                                    _settings.coreColor = c;
                                    _timeSincePaused = 0.0;
                                  });
                                },
                              ),
                            );

                            // If cancelled, restore original colors
                            if (result != true) {
                              both(() {
                                _settings.outerColor = origOuter;
                                _settings.midColor = origMid;
                                _settings.coreColor = origCore;
                                _timeSincePaused = 0.0;
                              });
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => both(() {
                  _settings.resetToDefaults();
                  _dampening = 1.0;
                  _timeSincePaused = 0.0;
                }),
                child: const Text('Reset Plugin Defaults'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------- UI ----------------

  String _formatTime(double seconds) {
    final int mins = seconds ~/ 60;
    final int secs = seconds.toInt() % 60;
    final int cs = ((seconds % 1) * 100).toInt();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}:${cs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final bool loaded = _audio != null;

    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.space) {
            _togglePlay();
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _exporting) {
            _cancelToken?.cancel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            // --- Visualizer ---
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final int w = constraints.maxWidth.floor();
                  final int h = constraints.maxHeight.floor();
                  WidgetsBinding.instance.addPostFrameCallback((_) => _onViewSized(w, h));
                  return CustomPaint(
                    size: Size.infinite,
                    painter: VizBlitPainter(
                      frame: _compositor?.image,
                      repaintKey: _frameCounter,
                      backgroundColor: Color(_settings.backgroundColor),
                    ),
                  );
                },
              ),
            ),

            // --- Status line ---
            if (_statusMessage != null)
              Container(
                width: double.infinity,
                color: const Color(0xFF141414),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(_statusMessage!, style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA))),
              ),

            // --- Export progress ---
            if (_exporting)
              Container(
                color: const Color(0xFF141414),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    const Text('Exporting Video: ', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: _exportTotal > 0 ? _exportDone / _exportTotal : null,
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('$_exportDone / $_exportTotal'),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: () => _cancelToken?.cancel(),
                      child: const Text('Cancel (Esc)'),
                    ),
                  ],
                ),
              ),

            // --- Timeline (scrub) ---
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: loaded && !_exporting ? (d) => _scrubTo(d.localPosition.dx / context.size!.width) : null,
              onHorizontalDragUpdate: loaded && !_exporting ? (d) => _scrubTo(d.localPosition.dx / context.size!.width) : null,
              onHorizontalDragEnd: loaded ? (_) => setState(() => _scrubbing = false) : null,
              onTapDown: loaded && !_exporting
                  ? (d) {
                      _scrubTo(d.localPosition.dx / context.size!.width);
                      setState(() => _scrubbing = false);
                    }
                  : null,
              child: SizedBox(
                height: 24,
                child: LayoutBuilder(
                  builder: (ctx, c) {
                    final double frac = _totalTime > 0 ? _currentTime / _totalTime : 0.0;
                    return Stack(children: [
                      Container(color: const Color(0xFF141414)),
                      FractionallySizedBox(
                        widthFactor: frac.clamp(0.0, 1.0),
                        child: Container(color: const Color(0xFF286428)),
                      ),
                    ]);
                  },
                ),
              ),
            ),

            // --- Transport bar ---
            Container(
              color: const Color(0xFF141414),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Text(
                    loaded
                        ? '${_formatTime(_currentTime)} / ${_formatTime(_totalTime)}'
                        : (_loading ? 'Loading...' : 'No Audio Loaded - Click Load Audio'),
                    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                  const Spacer(),

                  // Visualization selector
                  DropdownButton<Visualization>(
                    value: _viz,
                    isDense: true,
                    items: _visualizations
                        .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text(v.name, style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: _exporting
                        ? null
                        : (v) {
                            if (v != null) _selectViz(v);
                          },
                  ),
                  const SizedBox(width: 12),

                  // Device dropdown
                  if (_devices.isNotEmpty)
                    DropdownButton<PlaybackDevice>(
                      value: _selectedDevice,
                      isDense: true,
                      items: _devices
                          .map((d) => DropdownMenuItem(
                                value: d,
                                child: Text(d.description, style: const TextStyle(fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: _exporting
                          ? null
                          : (d) async {
                              final bool wasPlaying = _playing;
                              await _stopPlayback();
                              setState(() => _selectedDevice = d);
                              if (wasPlaying) await _startPlayback();
                            },
                    ),
                  const SizedBox(width: 12),

                  OutlinedButton(
                    onPressed: loaded && !_exporting ? _export : null,
                    child: const Text('Export Video'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _exporting ? null : _openSettings,
                    child: const Text('Settings'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: loaded && !_exporting && _playback != null ? _togglePlay : null,
                    child: Text(_playing ? 'Pause' : 'Play'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading || _exporting ? null : _loadAudio,
                    child: const Text('Load Audio'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom Color Picker Dialog
// ---------------------------------------------------------------------------

class _CustomColorPickerDialog extends StatefulWidget {
  final int outer;
  final int mid;
  final int core;
  final void Function(int outer, int mid, int core) onChanged;

  const _CustomColorPickerDialog({
    required this.outer,
    required this.mid,
    required this.core,
    required this.onChanged,
  });

  @override
  State<_CustomColorPickerDialog> createState() => _CustomColorPickerDialogState();
}

class _CustomColorPickerDialogState extends State<_CustomColorPickerDialog> {
  late Color _outer;
  late Color _mid;
  late Color _core;

  @override
  void initState() {
    super.initState();
    _outer = Color(widget.outer);
    _mid = Color(widget.mid);
    _core = Color(widget.core);
  }

  void _notifyChange() {
    widget.onChanged(_outer.value, _mid.value, _core.value);
  }

  Widget _buildSlider(String label, int value, Color activeColor, ValueChanged<int> onChanged) {
    return Row(
      children: [
        SizedBox(width: 20, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: 0,
            max: 255,
            activeColor: activeColor,
            onChanged: (v) => onChanged(v.toInt()),
          ),
        ),
        SizedBox(width: 30, child: Text(value.toString().padLeft(3, ' '))),
      ],
    );
  }

  Widget _buildColorTab(Color color, ValueChanged<Color> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async {
                final Color? picked = await showDialog<Color>(
                  context: context,
                  builder: (ctx) => _SwatchPickerDialog(),
                );
                if (picked != null) {
                  onChanged(picked);
                }
              },
              child: Container(
                height: 48,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.palette, color: Colors.white, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                      SizedBox(width: 8),
                      Text('Tap for swatches', style: TextStyle(color: Colors.white, shadows: [Shadow(color: Colors.black54, blurRadius: 4)], fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSlider('R', color.red, Colors.red, (v) => onChanged(color.withRed(v))),
          _buildSlider('G', color.green, Colors.green, (v) => onChanged(color.withGreen(v))),
          _buildSlider('B', color.blue, Colors.blue, (v) => onChanged(color.withBlue(v))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom Palette'),
      content: SizedBox(
        width: 320,
        child: DefaultTabController(
          length: 3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Outer'),
                  Tab(text: 'Mid'),
                  Tab(text: 'Core'),
                ],
              ),
              SizedBox(
                height: 240,
                child: TabBarView(
                  children: [
                    _buildColorTab(_outer, (c) {
                      setState(() => _outer = c);
                      _notifyChange();
                    }),
                    _buildColorTab(_mid, (c) {
                      setState(() => _mid = c);
                      _notifyChange();
                    }),
                    _buildColorTab(_core, (c) {
                      setState(() => _core = c);
                      _notifyChange();
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Swatch Picker Dialog
// ---------------------------------------------------------------------------

class _SwatchPickerDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final List<Color> swatches = [
      Colors.red, Colors.pink, Colors.purple, Colors.deepPurple,
      Colors.indigo, Colors.blue, Colors.lightBlue, Colors.cyan,
      Colors.teal, Colors.green, Colors.lightGreen, Colors.lime,
      Colors.yellow, Colors.amber, Colors.orange, Colors.deepOrange,
      Colors.brown, Colors.grey, Colors.blueGrey, Colors.white,
      Colors.black,
    ];

    return AlertDialog(
      title: const Text('Select a Color'),
      content: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: swatches.map((Color c) {
          return Material(
            color: c,
            shape: CircleBorder(
              side: BorderSide(
                color: c == Colors.black ? Colors.white24 : Colors.transparent, 
                width: 1
              )
            ),
            clipBehavior: Clip.antiAlias,
            elevation: 2,
            child: InkWell(
              onTap: () => Navigator.pop(context, c),
              child: const SizedBox(width: 40, height: 40),
            ),
          );
        }).toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}