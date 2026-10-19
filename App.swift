import SwiftUI
import AppKit

@main
struct ArgonAudioMixerApp: App {
    @StateObject private var deviceManager: AudioDeviceManager
    @StateObject private var tapEngine: ProcessTapEngine

    init() {
        let devices = AudioDeviceManager()
        let engine = ProcessTapEngine(outputDeviceUID: devices.defaultOutputDeviceUID)
        devices.onDefaultOutputDeviceChanged = { [weak engine] uid in
            engine?.setOutputDeviceUID(uid)
        }
        _deviceManager = StateObject(wrappedValue: devices)
        _tapEngine = StateObject(wrappedValue: engine)
    }

    var body: some Scene {
        MenuBarExtra {
            MixerPopoverView(
                deviceManager: deviceManager,
                tapEngine: tapEngine
            )
        } label: {
            HStack(spacing: 3) {
                Image(systemName: statusBarIconName)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var statusBarIconName: String {
        if deviceManager.isInputMuted {
            return "mic.slash.fill"
        }
        if deviceManager.isOutputMuted {
            return "speaker.slash.fill"
        }
        return "waveform.and.mic"
    }
}
