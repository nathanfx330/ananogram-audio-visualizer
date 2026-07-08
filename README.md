# Ananogram

**A modern audiovisual synthesis engine for motion graphics, broadcast, and post-production.**

Ananogram revives music visualization as a serious creative medium—not as a consumer effect or real-time toy, but as a deterministic system for generating sound-driven visual material inside professional production pipelines.

It produces *visual artifacts*, not finished videos: clean, composable plates designed for use in After Effects, Fusion, Nuke, Blender, Resolve, and any compositor that expects precision.

---

# Core Idea

Modern audio visualization has largely converged on playback effects, templates, and live performance tools.

Ananogram approaches the problem differently.

It treats audio as structured input for visual synthesis.

```text
Sound
    ↓
Structure
    ↓
Visual Form
    ↓
Production Material
```

Rather than decorating playback, Ananogram synthesizes reusable visual assets that become part of a larger compositing workflow.

---

# System Overview

Ananogram is a deterministic audiovisual synthesis engine with separate architectures for interactive preview and production export.

Both pipelines evaluate the exact same visualization model, but each is optimized for a different engineering problem.

```text
Audio
    ↓
Decoding (WAV / FFmpeg)
    ↓
Signal Analysis
(FFT • Envelope • Bands)
    ↓
Visualization Plugin
(Time-based Evaluation)
           │
    ┌──────┴──────┐
    │             │
GPU Preview   CPU Export
    │             │
Interactive   Parallel Batch
    └──────┬──────┘
           ↓
Compositing
           ↓
Production-ready Plates
```

The preview renderer prioritizes responsiveness, smooth interaction, and immediate visual feedback.

The export renderer prioritizes throughput, determinism, compositing fidelity, and efficient multi-core utilization.

Although implemented independently, both pipelines evaluate identical visualization logic, ensuring visual consistency between preview and final output.

---

# Key Properties

## Deterministic by Design

* Bit-identical output across repeated exports at the same framerate
* Continuous-time evaluation rather than frame-dependent simulation
* Framerate-independent visuals: 30 fps and 60 fps exports look identical
* No simulation drift between preview and final render

Every visualization is evaluated as a function of time instead of frame number, using pure arithmetic on typed data with no GPU or engine involvement. Repeated exports at the same settings are byte-for-byte identical.

Framerate independence is a separate, visual guarantee rather than a bit-exact one: temporal recurrences are evaluated as `pow(x, 30·dt)` so time constants stay fixed in seconds, but the 8-bit trail decay accumulates marginally different truncation per frame at different rates—imperceptible in the image, not byte-equal in the faintest tail.

---

## Professional Compositing Workflow

Ananogram generates production assets rather than presentation media.

Its output is intended for compositing inside professional post-production applications.

Features include:

* Premultiplied alpha correctness throughout the pipeline
* ProRes 4444 straight alpha workflows
* H.264 luma matte workflows
* Frame-accurate deterministic exports
* Metadata sidecars for reproducibility

---

## Interactive Authoring

Real-time preview is a first-class part of the system.

The interactive renderer provides responsive editing, parameter adjustment, synchronized playback, and GPU-accelerated visualization while sharing the same deterministic evaluation model used during export.

Interactive performance and export performance are treated as separate optimization problems rather than competing requirements within a single renderer.

---

# Visualization System

Visualization is built around modular deterministic plugins.

Each plugin maps analyzed audio features into visual geometry through continuous-time evaluation.

Plugins receive structured analysis data rather than raw audio, allowing each visualization to operate independently of the decoding pipeline.

Typical inputs include:

* Current playback time
* Delta time
* Waveform samples
* FFT spectrum
* Frequency bands
* Envelope data
* User parameters

FFT computation is performed lazily, ensuring plugins that do not require frequency-domain analysis incur no unnecessary processing cost.

## Included Systems

* **Phosphor Waveform** — persistent analog oscilloscope rendering
* **Spectrum Bars** — logarithmic frequency decomposition (20 Hz–16 kHz)
* **Line Spectrum** — smooth spectral curve
* **Circular Spectrum** — radial harmonic geometry
* **Ridge Plot (Waterfall)** — scrolling spectral history
* **Dot Matrix** — LED/VFD-style equalizer
* **Minimalist Halo** — circular low-frequency energy field
* **Vocal Telemetry (Forensic)** — forensic polygraph-style voice analysis
* **Voiceprint Spectrogram** — frequency-over-time heatmap
* **Terminal Waves** — additive harmonic interference rendered on an ASCII grid

---

# Rendering Architecture

Ananogram intentionally separates interactive rendering from production rendering.

## Live Preview Engine

The preview renderer is GPU-accelerated and optimized for authoring.

Features include:

* Smooth real-time playback
* Immediate parameter updates
* Stable history buffers
* Zero recursive display structures
* Constant VRAM usage

Its goal is responsiveness rather than maximum rendering throughput.

## Production Export Engine

Export runs on a dedicated pure-Dart software rasterizer (`SoftCanvas`), distributing rendering across available CPU cores. When every active plugin has a software port—the current default—export bypasses the GPU entirely; a plugin without a software implementation falls back to the GPU render path automatically.

Each worker renders a contiguous frame range and streams raw RGBA directly into its own FFmpeg process, which encodes a lossless FFV1 segment. The segments are then stitched by frame-accurate concatenation (stream copy, no re-encode) and the audio is muxed in a single final pass.

This architecture provides:

* Linear scaling with CPU cores
* Constant memory usage, independent of clip length
* No PNG/image-sequence intermediates
* Deterministic output
* Backpressure-aware streaming (the OS pipe blocks each worker when its encoder falls behind)

Interactive rendering and production rendering solve different optimization problems and therefore use different implementations while sharing the same visualization model.

---

# Export System

Exports stream through FFmpeg into production-ready deliverables.

Supported formats:

* **ProRes 4444** — straight-alpha, for the widest compositor compatibility
* **H.264 + luma matte** — a fill/matte pair reconstructed as fill × matte
* **H.264 over a solid background** — any background color; black composites by dropping the alpha plane, other colors are composited over a generated source

For the two H.264 paths, NVENC hardware encoding is available as an experimental opt-in; CPU (`libx264`) is the default and the known-good path. NVENC is an encoder choice, not a separate format, and does not apply to ProRes.

Every export also writes a JSON sidecar next to the video, recording everything needed to reproduce the bake:

* Source and output paths
* Renderer path (CPU or GPU) and schema version
* Visualization name and full style block
* Plugin parameters
* Format, codec, framerate, and geometry
* Performance telemetry
* Creation timestamp

This allows rendered assets to be reproduced exactly at a later date.

---

# Current Limitations

* Linux only
* Export pipeline depends on POSIX named FIFOs (`mkfifo`)
* FFmpeg required
* NVENC support is experimental

---

# Roadmap

## Analysis

* Beat and onset detection
* Stereo visualization
* Multi-channel analysis
* Expanded feature extraction

## Pipeline

* OpenEXR HDR workflows
* Open visualization SDK
* Cross-compositor preset exchange
* Additional production export formats

---

# Requirements

## Required

* Linux
* Flutter Desktop
* FFmpeg available on `PATH`
* POSIX FIFO support (`mkfifo`)

## Optional

* `paplay` or `aplay`
* `zenity` or `kdialog`

---

# Design Intent

Ananogram is not a music video generator.

It is an audiovisual synthesis engine for producing composable visual material from sound.

It occupies the space between instrument, renderer, and compositing tool—treating audio as structured input for deterministic visual synthesis rather than as a trigger for playback effects.

Its goal is to restore audio visualization as a serious production medium while fitting naturally into modern post-production workflows.

---

# License

MIT License

Copyright (c) 2026 Nathaniel Westveer

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