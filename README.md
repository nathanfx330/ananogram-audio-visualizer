# Ananogram

**An offline audio visualization plate generator for documentary, broadcast, and motion graphics workflows.**

Ananogram is a Linux desktop application for generating high-quality, deterministic audio visualization assets designed to be composited into professional video productions.

Unlike traditional "music visualizer" applications, Ananogram is built around a post-production workflow. It renders clean visualization plates—with proper alpha—that drop directly into Adobe After Effects, DaVinci Resolve Fusion, Nuke, Blender, or any compositor.

---

## Features

### Professional Export Pipeline

- Offline deterministic rendering—never screen recording
- Frame-perfect exports at exact frame rates
- Raw RGBA frames streamed directly to FFmpeg through a named pipe—no intermediate image sequences or temporary files
- Dedicated writer thread with OS-native pipe backpressure; memory usage stays flat regardless of export length
- Correct premultiplied-alpha handling end to end—glow falloffs export exactly as rendered, with no double-multiplied darkening
- JSON metadata sidecar written alongside every export, recording source audio, visualization, format, geometry, and complete style settings for exact reproducibility

### Export Formats

- **ProRes 4444** with embedded alpha (`pcm_s16le` audio)
- **H.264 over solid black** (`AAC 320 kbps` audio)
- **H.264 color + luma matte pair** for alpha workflows in H.264-only pipelines
- Optional **NVENC** hardware encoding *(experimental, opt-in; CPU encoding remains the default and recommended path)*

**Supported resolutions**

- 720p
- 1080p
- 1440p
- 4K

**Supported frame rates**

- 24 fps
- 30 fps
- 60 fps

---

## Visualization Plugins

Ananogram uses a plugin-based rendering architecture. Each plugin implements a minimal interface—`reset()` and `render()`—against a per-frame context that provides lazy, cached FFT analysis (magnitude spectrum plus bass/mid/treble band energies). Plugins that don't require FFT analysis incur zero FFT overhead.

Included visualizations:

- **Phosphor Waveform** — AGC-driven oscilloscope with triple-stroke phosphor glow
- **Spectrum Bars** — 64 logarithmically spaced bands (20 Hz–16 kHz)
- **Circular Spectrum** — radial 128-band spectrum analyzer
- **Ridge Plot** — pseudo-3D scrolling spectrum waterfall
- **Dot Matrix** — LED/VFD-style equalizer grid
- **Bass Halo** — minimalist circular waveform driven by bass energy

Shared style controls include:

- Phosphor color palettes
- Trail persistence
- Glow blur
- Stroke weight
- Time window
- Amplitude

---

## Audio Support

- **WAV** decoding is implemented entirely in pure Dart, including:
  - Full RIFF parsing
  - PCM 8/16/24/32-bit
  - IEEE Float 32/64
  - `WAVE_FORMAT_EXTENSIBLE`
  - Pure-Dart windowed-sinc polyphase resampler
- **All other formats** (MP3, FLAC, OGG, M4A, and virtually any production format) are decoded through FFmpeg.

All audio is internally converted to normalized mono `Float32` at **44.1 kHz** for consistent analysis and rendering.

---

## Built for Motion Graphics

Typical workflow:

```text
Audio
    │
    ▼
Ananogram
    │
    ▼
Rendered Visualization Plate
    │
    ▼
After Effects · Fusion · Blender
Nuke · Premiere · Resolve
    │
    ▼
Final Composite
```

Ananogram creates reusable visual elements—not finished videos.

---

## Rendering Architecture

```text
Audio
    │
    ▼
Decode (pure Dart WAV / FFmpeg)
    │
    ▼
Analysis (pure Dart FFT, lazy per-frame)
    │
    ▼
Visualization Plugin
    │
    ▼
Frame Compositor
(trail decay + strict GPU frame ownership)
    │
    ▼
Named Pipe → Writer Thread
    │
    ▼
FFmpeg Encoder
```

Every visualization plugin is held to a determinism contract:

> Calling `reset()` followed by rendering the same sequence of timestamps must always produce identical output.

That contract allows any visualization to be rendered offline while remaining reproducible from identical inputs.

The frame compositor uses an explicit GPU frame ownership model during export. Exactly **two textures** are ever alive simultaneously, so VRAM usage remains constant whether exporting ten seconds or two hours of footage.

---

## Technical Highlights

- Flutter desktop application (Linux-first)
- Zero pub dependencies
- Pure Dart DSP, FFT, WAV decoding, and resampling
- Plugin-based visualization architecture with lazy shared analysis
- GPU rasterization with disciplined texture lifetime management
- FIFO + writer-isolate export pipeline (blocking system writes off the UI thread)
- Correct premultiplied-alpha pipeline into FFmpeg
- Per-export JSON bake records for reproducibility
- Subprocess audio playback (`paplay` / `aplay`) with output-device enumeration
- Built-in per-stage export profiling (render / readback / pipe wait)

---

## Project Goals

Ananogram exists to generate clean, reusable visualization plates for professional post-production.

Typical applications include:

- Documentary films
- Broadcast television
- Motion graphics
- Educational media
- Scientific visualization
- Podcasts
- Corporate video
- YouTube productions

---

## Known Limitations

These are known issues and active development priorities.

- **Frame-rate-dependent smoothing.** Plugin smoothing constants (AGC and per-band decay) are currently applied per frame rather than per second. A live preview running at monitor refresh and an export rendered at 24/30/60 fps therefore decay at slightly different rates. Trail persistence already matches between preview and export; smoothing parity is the remaining gap.
- **Export render latency.** Offline rendering is currently limited by GPU rasterization round-trip scheduling (approximately **40 ms/frame at 720p**), rather than rasterization itself. Encoding and pipe throughput have already been optimized; render dispatch remains the primary bottleneck.
- **Linux only.** macOS and Windows are not currently supported. Playback backends and the FIFO export pipeline are POSIX-specific.
- **NVENC is experimental.** Hardware encoding is available as an opt-in feature. CPU encoding remains the supported production path.

---

## Future Development

### Performance

- Eliminate the render round-trip bottleneck (batched rasterization or CPU raster path)
- Frame-rate-independent smoothing using `pow(k, dt × fps_ref)` for exact preview/export parity
- Audio feature cache (precomputed FFT/onset analysis reused across exports)
- GPU compute acceleration for audio analysis

### Visualizations

- Additional visualization plugins
- Spectrogram rendering
- Shared beat and onset detection
- Multi-channel / stereo analysis

### Pipeline

- PNG and EXR image sequence export
- Additional alpha workflow options
- HDR rendering
- Open plugin SDK

---

## Requirements

- Flutter (Linux desktop)
- FFmpeg available on the system `PATH`
- `mkfifo` (standard on virtually every Linux distribution) for the export pipeline

Optional:

- `zenity` or `kdialog` for the native file picker
- `paplay` or `aplay` for audio preview *(exports work without playback support)*

Linux is currently the primary supported platform.

---

## Philosophy

Ananogram is not intended to generate flashy one-click music videos.

It is a production tool that creates high-quality visualization plates for editors, motion designers, and documentary filmmakers—built with zero external package dependencies, local-first, and deterministic by contract.

The visualization is only one layer of the finished composition.

