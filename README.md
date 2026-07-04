# Ananogram

**An offline audio visualization plate generator for documentary, broadcast, and motion graphics workflows.**

Ananogram is a desktop application for generating high-quality, deterministic audio visualization assets that are designed to be composited into professional video productions.

Unlike traditional "music visualizer" applications, Ananogram is built around a post-production workflow. It renders clean visualization plates with alpha support that can be brought directly into Adobe After Effects, DaVinci Resolve Fusion, Nuke, Blender, or any compositor.

---

# Features

## Professional Export Pipeline

- Offline deterministic rendering
- Frame-perfect exports
- No screen recording
- Native FFmpeg rendering pipeline
- No intermediate image sequences required
- Export metadata sidecars for reproducibility

## Export Formats

- ProRes 4444 with alpha
- H.264 with solid black background
- H.264 color + luma matte pair

Supported resolutions include:

- 720p
- 1080p
- 1440p
- 4K

Supported frame rates include:

- 24 fps
- 30 fps
- 60 fps

---

# Visualization Plugins

Ananogram uses a plugin-based rendering architecture.

Included visualizations currently include:

- Phosphor Waveform
- Circular Spectrum
- Spectrum Bars
- Ridge Plot
- Dot Matrix
- Bass Halo

Each visualization renders deterministically, allowing identical results between preview and export.

---

# Audio Support

Audio is decoded through FFmpeg, allowing support for virtually every common production format.

Examples include:

- WAV
- MP3
- FLAC
- OGG
- M4A

All audio is internally converted to normalized mono Float32 for consistent analysis and rendering.

---

# Built for Motion Graphics

The intended workflow is:

```
Audio
    │
    ▼
Ananogram
    │
    ▼
Rendered Visualization Plate
    │
    ▼
After Effects
Fusion
Blender
Nuke
Premiere
Resolve
    │
    ▼
Final Composite
```

Ananogram is designed to create reusable visual elements—not finished videos.

---

# Rendering Architecture

The renderer is fully deterministic.

```
Audio
    │
    ▼
Decode
    │
    ▼
Analysis
    │
    ▼
Visualization Plugin
    │
    ▼
Frame Compositor
    │
    ▼
FFmpeg Encoder
```

This guarantees that exported frames exactly match live previews.

---

# Technical Highlights

- Flutter desktop application
- Pure Dart DSP
- Pure Dart FFT implementation
- Plugin visualization system
- GPU rasterization
- FFmpeg export pipeline
- Deterministic rendering
- Alpha-capable rendering
- Export manifests for reproducibility

---

# Project Goals

Ananogram exists to generate clean, reusable visualization plates for professional post-production.

Typical uses include:

- Documentary films
- Broadcast television
- Motion graphics
- Educational media
- Scientific visualization
- Podcasts
- Corporate video
- YouTube productions

---

# Future Development

Planned improvements include:

- Additional visualization plugins
- Spectrogram rendering
- Beat and onset detection
- Audio feature cache
- Multi-channel analysis
- Image sequence export
- Open plugin SDK
- GPU compute acceleration
- HDR rendering
- Additional alpha workflows

---

# Requirements

- Flutter
- FFmpeg available on the system PATH

Linux is currently the primary supported platform.

---

# Philosophy

Ananogram is not intended to generate flashy one-click music videos.

It is a production tool that creates high-quality visualization plates for editors, motion designers, and documentary filmmakers.

The visualization is only one layer of the finished composition.
