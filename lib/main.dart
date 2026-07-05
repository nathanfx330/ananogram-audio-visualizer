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

import 'ffmpeg_decode.dart';
import 'frame_exporter.dart';
import 'playback.dart';
import 'visualization.dart';
import 'visualizer_painter.dart';
import 'wav_decoder.dart';

const int kTargetSampleRate = 44100;

void main() {
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

class _AnanogramHomeState extends State<AnanogramHome> with SingleTickerProviderStateMixin {
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

  // --- Export ---
  bool _exporting = false;
  int _exportDone = 0;
  int _exportTotal = 0;
  ExportCancelToken? _cancelToken;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _visualizations = buildVisualizations();
    _viz = _visualizations.first;
    _ticker = createTicker(_onTick)..start();
    _initPlayback();
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

    if (_playing) {
      final double wallElapsed = DateTime.now().difference(_playStartWall).inMicroseconds / 1e6;
      _currentTime = _playStartPos + wallElapsed;
      if (_currentTime >= _totalTime) {
        _currentTime = _totalTime;
        _playing = false;
        _playback?.stop();
      }
    }

    if (_viewW > 0 && _viewH > 0) {
      _compositor ??= VizCompositor(width: _viewW, height: _viewH);
      final VizContext ctx = VizContext(
        audio: _audio!,
        sampleRate: _sampleRate,
        t: _currentTime,
        frameIndex: _frameCounter,
        dt: dt,
        width: _viewW,
        height: _viewH,
        dampening: _dampening,
        settings: _settings,
      );
      _compositor!.advance(_viz, ctx);
      _frameCounter++;
    }

    setState(() {});
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
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Trail Persistence: ${(_settings.trailRetention * 100).round()}%'),
                    Slider(
                      value: _settings.trailRetention,
                      max: 0.98,
                      onChanged: (v) => both(() => _settings.trailRetention = v),
                    ),

                    Text('Glow Blur: ${_settings.glowBlurSigma.toStringAsFixed(1)} px'),
                    Slider(
                      value: _settings.glowBlurSigma,
                      max: 8.0,
                      onChanged: (v) => both(() => _settings.glowBlurSigma = v),
                    ),

                    Text('Stroke Width: ${(_settings.strokeScale * 100).round()}%'),
                    Slider(
                      value: _settings.strokeScale,
                      min: 0.25,
                      max: 4.0,
                      onChanged: (v) => both(() => _settings.strokeScale = v),
                    ),
                    const Divider(height: 24),

                    // --- Phosphor color ---
                    const Text('Phosphor Palette', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _phosphorPresets.map((p) {
                        final bool active = _presetMatches(p);
                        return ChoiceChip(
                          label: Text(p.name),
                          selected: active,
                          avatar: CircleAvatar(backgroundColor: p.mid, radius: 8),
                          onSelected: (_) => both(() {
                            _settings.outerColor = p.outer.value;
                            _settings.midColor = p.mid.value;
                            _settings.coreColor = p.core.value;
                          }),
                        );
                      }).toList(),
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