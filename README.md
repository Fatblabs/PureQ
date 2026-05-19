# PureQ 🎛️

[![Platform](https://img.shields.io/badge/Platform-macOS%2014.2+-blue.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138.svg)]()
[![Architecture](https://img.shields.io/badge/Architecture-CoreAudio%20%7C%20AVFoundation-lightgrey)]()

**PureQ** is a high-performance, native macOS system-wide parametric equalizer and node-based audio router. 

Built entirely in Swift and C using Apple's modern `AVFoundation` and low-level `CoreAudio` APIs, PureQ allows you to capture system audio or isolate specific running applications, route them through custom parametric EQ nodes, and lock your playback to a dedicated hardware output.

---

## ✨ Features

* **Node-Based Audio Routing:** Visually patch audio sources (System Mix, Safari, Spotify, Games) to distinct Equalizer profiles and direct them to specific hardware outputs using a flexible, drag-and-drop node canvas.
* **Precision Parametric Equalizer:** Switch between 10-band, 31-band, or fully custom frequency layouts. Adjust gain, Q-factor, and filter shapes (Bell, Shelf, Notch) with real-time audio smoothing and auto-preamp gain staging.
* **App-Specific Process Taps:** On macOS 14.2+, PureQ uses native `AudioHardwareCreateProcessTap` to cleanly intercept audio from individual apps without installing kernel extensions.
* **Output Lock & Guarding:** Automatically locks macOS to your preferred speakers or headphones. If your device disconnects, PureQ suppresses unwanted fallback devices (like your MacBook speakers) to prevent embarrassing audio leaks.
* **Real-Time Spectrum Analyzer:** A highly responsive FFT spectrum analyzer (`vDSP` powered) integrated directly behind your EQ curve.
* **Menu Bar Integration:** Quickly toggle the EQ, adjust the preamp, change your target output, or swap presets without opening the main window.
* **Import/Export Profiles:** Save your finely tuned audio profiles as `.pureqeq` files and share them.

---

## 🚀 Installation

PureQ is distributed as a pre-compiled macOS Application. You do not need to build it from source to use it.

1. Go to the **[Releases](../../releases)** page.
2. Download the latest `PureQ.dmg` file.
3. Open the `.dmg` and drag the **PureQ** app into your `Applications` folder.
4. Launch PureQ. *(Note: You may need to right-click and select "Open" on the first launch due to macOS Gatekeeper if the app is unsigned).*

---

## 🏗️ Architecture & Codebase Overview

For developers interested in how PureQ manipulates macOS audio, the project is split into a SwiftUI frontend and a CoreAudio/AVEngine backend:

### 1. The Audio Engine (`AudioEngineService.swift`)
The heart of the app. It constructs an `AVAudioEngine` topology on the fly. Depending on your macOS version and routing graph, it either hooks into a running application via `CATapDescription` or falls back to capturing the `PureQ Virtual Output` loopback driver. It manages `AVAudioUnitEQ` nodes and calculates multi-band parametric filters in real time.

### 2. Output Device Management (`AudioOutputService.swift`)
A pure CoreAudio wrapper that queries `kAudioHardwarePropertyDevices`. It handles dynamically switching the macOS default output device, detecting hardware sample rates, and muting fallback speakers (`kAudioDevicePropertyMute`) to enforce the Output Lock feature.

### 3. The CoreAudio HAL Driver (`PureQDriver.c`)
A lightweight, user-space Audio Server Plug-in written in C. It registers a virtual audio device (`PureQ Virtual Output`) and a shared memory ring buffer (`/tmp/PureQAudioRing.v1`). For older systems or specific routing needs, this driver acts as a "dummy" output that macOS targets, allowing the PureQ Swift app to tap the buffer and process the global mix.

### 4. Reactive State (`EqualizerModel.swift`)
The `@MainActor` Observable Object. It acts as the source of truth for the node routing canvas, connection validations, active EQ bands, presets (e.g., Bass Lift, Vocal Focus), telemetry polling, and saving/restoring your session (`.pureqsession.json`).

### 5. Native SwiftUI Interface (`ContentView.swift` & `PureQApp.swift`)
PureQ features a custom, hardware-accelerated UI utilizing SwiftUI `Canvas` for drawing the active audio connections, the FFT spectrum graph, and custom vertical faders. It scales seamlessly from a full-window routing workspace down to a compact Menu Bar extra.

---

## 🛠️ Building from Source

If you want to contribute or build PureQ yourself:

1. Clone the repository: `git clone https://github.com/yourusername/PureQ.git`
2. Open `PureQ.xcodeproj` in Xcode 15+.
3. **Important:** PureQ uses a C-based CoreAudio driver. Ensure the `PureQDriver` target is built and embedded into the app bundle. To install the driver manually for local testing, copy `PureQ.driver` to `/Library/Audio/Plug-Ins/HAL/` and restart `coreaudiod` (`sudo killall coreaudiod`).
4. Select your Mac as the destination and hit `Cmd + R` to run.

---

## 📝 License

This project is open-source and available under the MIT License.
