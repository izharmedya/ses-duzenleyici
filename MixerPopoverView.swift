import SwiftUI
import ServiceManagement

final class MixerUIState: ObservableObject {
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @Published var expandOutputDevices: Bool = false
}

struct MixerPopoverView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    @ObservedObject var tapEngine: ProcessTapEngine
    @StateObject private var uiState = MixerUIState()

    private var activeOutputUID: String? {
        deviceManager.outputDevices.first(where: { $0.id == deviceManager.defaultOutputDeviceID })?.uid
    }

    private var filteredProcesses: [AudioAppProcess] {
        if tapEngine.showOnlyActiveAudio {
            return tapEngine.processes.filter { $0.isPlayingAudio || tapEngine.volume(for: $0.id) != 1.0 || tapEngine.isMuted(for: $0.id) }
        }
        return tapEngine.processes
    }

    private var statusMessage: String? {
        deviceManager.lastErrorMessage ?? tapEngine.lastErrorMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.4)

            if let statusMessage {
                statusBanner(statusMessage)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    microphoneSection
                    Divider().opacity(0.35)
                    outputSection
                    Divider().opacity(0.35)
                    perAppMixerSection
                }
                .padding(14)
            }
            .frame(minHeight: 380, maxHeight: 520)

            Divider().opacity(0.4)
            footerBar
        }
        .frame(width: 360, height: 520)
        .background(.ultraThinMaterial)
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            if tapEngine.showCaptureSettingsAction {
                Button("İzin ayarları") {
                    tapEngine.openSystemAudioCaptureSettings()
                }
                .font(.system(size: 9, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .fixedSize()
            }
            Spacer(minLength: 0)
            Button {
                deviceManager.clearError()
                tapEngine.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Üst Başlık

    private var headerBar: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.below.waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Ses Düzenleyici")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            Button {
                deviceManager.refreshAll()
                tapEngine.refreshProcesses()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Aygıtları ve uygulamaları yenile")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 1. Mikrofon (Giriş) Hızlı Geçiş & Kazanç Bölümü

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("MİKROFON (GİRİŞ)", systemImage: "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(inputStatusText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(deviceManager.isInputMuted ? .red : .secondary)
            }

            // Aktif Mikrofon Ses Seviyesi ve Hızlı Mute
            HStack(spacing: 8) {
                Button {
                    deviceManager.toggleInputMute()
                } label: {
                    Image(systemName: deviceManager.isInputMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(deviceManager.isInputMuted ? .white : .primary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(deviceManager.isInputMuted ? Color.red : Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Mikrofonu Sustur / Aç")
                .disabled(!deviceManager.canMuteInput)

                Slider(
                    value: Binding(
                        get: { Double(deviceManager.inputVolume) },
                        set: { deviceManager.setInputVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!deviceManager.canSetInputVolume)
            }

            if let notice = deviceManager.inputSupportNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Tek Tıkla Mikrofon Değiştirme Listesi
            VStack(spacing: 4) {
                ForEach(deviceManager.inputDevices) { device in
                    let isSelected = (device.id == deviceManager.defaultInputDeviceID)
                    Button {
                        deviceManager.selectInputDevice(device)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : device.systemIcon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .frame(width: 16)

                            Text(device.name)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .lineLimit(1)
                                .foregroundStyle(.primary)

                            Spacer()

                            Text(device.transportBadge)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 2. Ana Çıkış (Hoparlör / Kulaklık) Bölümü

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("ÇIKIŞ SESİ", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        uiState.expandOutputDevices.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(deviceManager.outputDevices.first(where: { $0.id == deviceManager.defaultOutputDeviceID })?.name ?? "Çıkış")
                            .lineLimit(1)
                        Image(systemName: uiState.expandOutputDevices ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button {
                    deviceManager.toggleOutputMute()
                } label: {
                    Image(systemName: deviceManager.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(deviceManager.isOutputMuted ? .white : .primary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(deviceManager.isOutputMuted ? Color.red : Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!deviceManager.canMuteOutput)
                .help(deviceManager.canMuteOutput ? "Çıkış sesini sustur / aç" : "Bu aygıt donanımsal mute desteklemiyor")

                Slider(
                    value: Binding(
                        get: { Double(deviceManager.outputVolume) },
                        set: { deviceManager.setOutputVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!deviceManager.canSetOutputVolume)

                Text(outputStatusText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(deviceManager.isOutputMuted ? .red : .secondary)
                    .frame(width: 88, alignment: .trailing)
            }

            if let notice = deviceManager.outputSupportNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if uiState.expandOutputDevices {
                VStack(spacing: 4) {
                    ForEach(deviceManager.outputDevices) { device in
                        let isSelected = (device.id == deviceManager.defaultOutputDeviceID)
                        Button {
                            deviceManager.selectOutputDevice(device)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : device.systemIcon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                Text(device.name)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer()
                                Text(device.transportBadge)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var inputStatusText: String {
        if deviceManager.isInputOperationPending { return "KONTROL EDİLİYOR" }
        if deviceManager.isInputMuted { return "SUSTURULDU" }
        if deviceManager.isInputGainAtMinimum { return "SEVİYE 0" }
        return "%\(Int(deviceManager.inputVolume * 100))"
    }

    private var outputStatusText: String {
        if deviceManager.isOutputOperationPending { return "KONTROL EDİLİYOR" }
        if deviceManager.isOutputMuted { return "SUSTURULDU" }
        if deviceManager.isOutputGainAtMinimum { return "SEVİYE 0" }
        return "%\(Int(deviceManager.outputVolume * 100))"
    }

    // MARK: - 3. Uygulama Bazlı Ses Mikseri (Per-App Volume Control)

    private var perAppMixerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("UYGULAMA MİKSERİ", systemImage: "waveform")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Sadece Aktif", isOn: $tapEngine.showOnlyActiveAudio)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if filteredProcesses.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "speaker.zzz")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text("Aktif ses kaynağı bulunamadı")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                    Spacer()
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(filteredProcesses) { proc in
                        appVolumeRow(for: proc)
                    }
                }
            }
        }
    }

    private func appVolumeRow(for proc: AudioAppProcess) -> some View {
        let currentVol = tapEngine.volume(for: proc.id)
        let isMuted = tapEngine.isMuted(for: proc.id)

        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: proc.icon)
                    .resizable()
                    .frame(width: 18, height: 18)

                Text(proc.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if proc.isPlayingAudio {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help("Şu anda ses çalıyor")
                }

                Spacer()

                // %100'e Sıfırlama Butonu (Eğer değiştirildiyse)
                if abs(currentVol - 1.0) > 0.01 {
                    Button("100%") {
                        tapEngine.setVolume(for: proc, volume: 1.0, currentOutputUID: activeOutputUID)
                    }
                    .font(.system(size: 9, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }

                Text(isMuted ? "MUTE" : "%\(Int(currentVol * 100))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isMuted ? .red : (currentVol > 1.02 ? .orange : .secondary))
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button {
                    tapEngine.toggleMute(for: proc, currentOutputUID: activeOutputUID)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isMuted ? .red : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                // %0 ile %150 (Overdrive Boost) arası kontrol
                Slider(
                    value: Binding(
                        get: { Double(currentVol) },
                        set: { tapEngine.setVolume(for: proc, volume: Float($0), currentOutputUID: activeOutputUID) }
                    ),
                    in: 0.0...1.5
                )
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Alt Çubuk (Launch at Login & Çıkış)

    private var footerBar: some View {
        HStack {
            Toggle("Başlangıçta Aç", isOn: $uiState.launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .onChange(of: uiState.launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        uiState.launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

            Spacer()

            Button("Sıfırla") {
                tapEngine.resetAllTaps()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)

            Button {
                tapEngine.resetAllTaps()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Uygulamadan Çık")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
