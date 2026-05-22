# PureQ 🎛️

[![Platform](https://img.shields.io/badge/Platform-macOS-blue)](https://github.com/Fatblabs/PureQ)
[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](https://github.com/Fatblabs/PureQ/blob/main/LICENSE)

PureQ is a native macOS system-wide parametric equalizer and node-based audio router. It provides per-application taps, flexible routing, and real-time EQ processing using a combination of Swift (SwiftUI) and a small CoreAudio driver.

Key goals:

- Low-latency, system-wide audio processing
- Per-app routing and EQ profiles
- Easy-to-use node-based routing canvas

---

## Highlights

- Node-based audio routing (system mix and per-app taps)
- Precision parametric EQ with customizable bands and filter types
- Optional virtual audio device driver for loopback routing (`PureQDriver.c`)
- Real-time spectrum analyzer and menu-bar controls
- Import/export EQ presets and session files

---

## Quick Install (end users)

Pre-built releases are the recommended way to use PureQ. Visit the Releases page and download the latest `.dmg`.

1. Open Releases: https://github.com/Fatblabs/PureQ/releases
2. Download `PureQ.dmg` for your macOS version.
3. Open the `.dmg` and drag the app into `/Applications`.
4. On first launch you may need to allow the app in System Settings → Privacy & Security if Gatekeeper blocks it.

---

## Build & Run (developers)

Requirements:

- macOS 14+ (development) — app will attempt to gracefully fall back on older OSes where possible
- Xcode 15+
- Swift 5.9

Steps to build locally:

```bash
git clone https://github.com/Fatblabs/PureQ.git
cd PureQ
open PureQ.xcodeproj
```

If you need the virtual audio driver for loopback routing (used by some routing modes), run the included helper script to install the driver locally:

```bash
sudo ./Scripts/install-pureq-driver.sh
# When done, restart coreaudiod if prompted:
sudo killall coreaudiod
```

Notes for developers:

- The Xcode workspace contains two primary targets: the SwiftUI app and a small C-based driver (`PureQDriver`).
- Building and embedding the driver requires proper code signing for distribution. For local testing the script places the driver under `/Library/Audio/Plug-Ins/HAL/`.

---

## Project structure (short)

- `PureQ/` — Swift/SwiftUI application sources
- `PureQDriver/` — C CoreAudio driver and helper sources
- `Scripts/` — install/uninstall helper scripts for the driver and packaging
- `build/` — Xcode build artifacts (ignored by git)

If you want to explore code paths mentioned in this README, start with:

- [PureQ/](PureQ) — UI and app logic
- [PureQDriver/](PureQDriver) — virtual device implementation
- [Scripts/install-pureq-driver.sh](Scripts/install-pureq-driver.sh) — driver install helper

---

## Contributing

Contributions are welcome. If you're submitting changes:

1. Fork the repo and create a feature branch.
2. Open a pull request against `main` with a clear description of the change.
3. If your change affects audio behavior, include reproduction steps and testing notes.

If you need help getting the driver installed for local development, open an issue and include your macOS version and Xcode version.

---

## Security & Privacy

PureQ interacts with system audio devices and may require permissions. The app does not collect telemetry by default. If you add diagnostic features, treat any logs with user consent and avoid recording raw audio.

---

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE) for details.
