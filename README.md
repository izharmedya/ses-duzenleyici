# Ses Düzenleyici

A native macOS utility for mixing and adjusting audio from running apps. The project is written in Swift and uses SwiftUI, Core Audio, and an audio process tap.

## Build

Requirements: macOS 14.2 or later and Xcode Command Line Tools.

```bash
./build.sh
open "build/Ses Düzenleyici.app"
```

The build script writes the app bundle into `build/`; it does not replace the copy in the source folder. macOS may ask you to grant audio capture permissions the first time the app runs.

## Project files

- `App.swift` — app entry point and window setup
- `MixerPopoverView.swift` — mixer interface
- `AudioDeviceManager.swift` and `ProcessTapEngine.swift` — device discovery and audio processing
- `RTAtomicBridge.h` — real-time-safe atomic bridge

## License

Original source code is MIT-licensed.
