# Ananogram

**A modern audiovisual synthesis engine for motion graphics, broadcast, and post-production.**

Ananogram revives music visualization as a serious creative medium—built not as a consumer effect or real-time toy, but as a deterministic system for generating sound-driven visual material inside professional production pipelines.

It produces *visual artifacts*, not finished videos: clean, composable plates designed to live inside After Effects, Fusion, Nuke, Blender, Resolve, and any compositor that expects precision.

---

## Core Idea

There was a time when audio visualization was experimental—systems that treated sound as a direct driver of visual form. Over time, that space collapsed into presets, templates, and shallow real-time effects.

Ananogram brings it back in a form that fits modern production reality:

* Sound becomes structure
* Structure becomes visual form
* Visual form becomes reusable production material

Not reactive decoration. Not playback gimmicks. A synthesis system.

---

## System Overview

Ananogram is a deterministic offline renderer for audio-driven visual systems.

It turns audio into frame-accurate visual outputs through a fully reproducible pipeline:

```text
Audio
  ↓
Decoding (WAV / FFmpeg)
  ↓
Signal Analysis (FFT + envelope + bands)
  ↓
Visualization System (plugin-driven)
  ↓
Frame Renderer (GPU)
  ↓
Compositing Layer (alpha-correct)
  ↓
Streaming Export (FFmpeg via pipe)
  ↓
Production-ready plates
```

Every stage is deterministic. Identical input produces identical output at any time, on any machine.

---

## Key Properties

### Deterministic by design

* Frame-perfect reproducibility
* Time-based evaluation instead of frame-dependent simulation
* No real-time state drift between preview and export

### Post-production native

* Outputs are designed for compositing, not playback
* Alpha-aware rendering pipeline (premultiplied correctness preserved end-to-end)
* EXR / ProRes / H.264 workflows supported

### Offline synthesis, not playback

* No live timing constraints
* No UI-driven simulation loop
* Rendering is a batch synthesis process

---

## Visualization System

Ananogram is built around modular visualization plugins.

Each plugin is a small deterministic function:

```text
render(audio_context, visual_state, time) → frame
```

Plugins do not “play audio.” They *interpret structure over time*.

### Included systems

* **Phosphor Waveform** – persistent analog-style oscilloscope rendering
* **Spectrum Bars** – logarithmic frequency decomposition (20 Hz–16 kHz)
* **Circular Spectrum** – radial harmonic geometry
* **Ridge Plot** – spectral history as spatial form
* **Dot Matrix** – grid-based amplitude encoding
* **Bass Halo** – low-frequency energy field visualization

Each system can operate with or without FFT input, allowing zero-cost rendering paths when analysis is unnecessary.

---

## Audio Pipeline

* WAV decoding implemented in pure Dart (full RIFF support)
* FFmpeg-backed decoding for all production formats (MP3, FLAC, OGG, M4A, etc.)
* Internal normalization to mono Float32 @ 44.1 kHz
* Polyphase sinc resampling for sample-accurate alignment

Audio is not treated as playback—it is treated as a data source.

---

## Rendering Architecture

Ananogram separates analysis, rendering, and export into isolated deterministic layers.

```text
Analysis Layer
  - FFT (lazy, cached)
  - envelope tracking
  - band energy extraction

↓

Visualization Layer
  - plugin evaluation
  - time-based state resolution

↓

Frame Compositor
  - GPU rasterization
  - alpha correctness enforcement
  - controlled texture lifetime (constant VRAM footprint)

↓

Export Layer
  - named pipe streaming
  - FFmpeg encoding
  - zero intermediate files
```

The system is designed so memory usage and output correctness do not degrade with duration.

---

## Export System

Ananogram exports directly into production formats via FFmpeg streaming pipelines.

### Supported outputs

* ProRes 4444 (alpha preserved)
* H.264 (black background or matte-separated workflows)
* NVENC hardware encoding (experimental, opt-in)
* PNG / EXR sequences (planned / extensible)

### Key properties

* No image sequence intermediates required
* Backpressure-aware pipe writer (constant memory usage)
* Frame-accurate encoding
* Full metadata sidecar for reproducibility

Each export produces a JSON descriptor containing:

* audio source hash
* plugin configuration
* render parameters
* resolution and frame rate
* analysis settings

---

## Performance Model

* GPU-driven frame rendering
* Strict two-texture lifetime model (constant VRAM usage)
* Lazy FFT computation (only when required)
* Isolated writer thread for encoding (UI never blocks)

The system is optimized for long-duration synthesis rather than interactive playback.

---

## Current Limitations

* **Frame-rate-dependent smoothing**
  Some temporal parameters are currently applied per-frame instead of per-second, leading to slight differences between preview and export at different frame rates.

* **GPU dispatch overhead**
  Rendering currently incurs per-frame round-trip latency (~40ms at 720p), which limits export throughput.

* **Linux-only**
  Built around POSIX assumptions (FIFO pipelines, audio backends, tooling).

* **Hardware encoding experimental**
  NVENC support exists but is not yet production-stable.

---

## Roadmap

### Temporal correctness

* Frame-rate-independent smoothing using continuous-time decay functions
* Unified preview/export evaluation model

* **Future update — pull floor-decay off the live compositor.**
  The real structural fix. Restores the fixed point so sustained playback goes quiescent, which means you could go back to vsync-rate live rendering and keep the GC happy, because idle scenes stop minting textures on their own. This is the one that actually dissolves the tradeoff instead of trading against it — but it's the two-file change (`soft_raster.dart` + `visualization.dart`) and it reintroduces the cosmetic preview/export haze mismatch at high retention.

### Performance

* Batched GPU rendering pipeline
* Reduced per-frame dispatch overhead
* Optional compute-shader-based signal processing

### Visual expansion

* Spectrogram renderer
* Beat/onset detection system
* Stereo and multi-channel spatial analysis
* Expanded plugin ecosystem

### Pipeline expansion

* EXR-first HDR workflows
* Open plugin SDK
* Cross-compositor preset exchange format

---

## Requirements

* Linux (primary platform)
* Flutter desktop runtime
* FFmpeg available on PATH
* mkfifo (standard POSIX support)

Optional:

* paplay / aplay (audio preview)
* zenity / kdialog (file dialogs)

---

## Design Intent

Ananogram is not a “music video maker.”

It is a system for generating audiovisual material as a compositional medium—something closer to an instrument than a template engine, and closer to a renderer than a player.

It exists to rebuild a category that once existed in a fragmented form, and to make it usable inside modern production environments without stripping away its expressive core.

---

# License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.