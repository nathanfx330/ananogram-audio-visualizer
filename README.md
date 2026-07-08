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

* Frame-perfect reproducibility
* Continuous-time evaluation rather than frame-dependent simulation
* Identical visual output regardless of preview or export framerate
* Stable rendering across machines and repeated exports

Every visualization is evaluated as a function of time instead of frame number. This eliminates simulation drift and preserves visual parity between live playback and rendered output.

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
* **Vocal Telemetry** — forensic polygraph-style voice analysis
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

Export bypasses the GPU entirely.

A dedicated software rasterizer (`SoftCanvas`) distributes rendering across available CPU cores.

Each worker renders independent frame ranges into isolated POSIX FIFOs, streaming lossless FFV1 segments directly into FFmpeg before performing frame-accurate concatenation.

This architecture provides:

* Linear scaling with CPU cores
* Constant memory usage
* No image sequence intermediates
* Deterministic output
* Backpressure-aware streaming

Interactive rendering and production rendering solve different optimization problems and therefore use different implementations while sharing the same visualization model.

---

# Export System

Exports stream directly through FFmpeg into production-ready formats.

Supported formats include:

* ProRes 4444 (straight alpha)
* H.264 with luma matte
* H.264 solid black background
* Experimental NVENC hardware encoding

Every export also generates a JSON sidecar containing:

* Project hash
* Renderer version
* Visualization configuration
* Plugin parameters
* Performance telemetry
* Export metadata

This allows rendered assets to be reproduced exactly at a later date.

---

# Current Limitations

* Linux only
* POSIX-based rendering pipeline
* FFmpeg required
* Experimental NVENC support

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
