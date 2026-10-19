import Foundation
import CoreAudio
import AudioToolbox
import Combine

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let isInput: Bool
    let isOutput: Bool
    let inputChannelCount: Int
    let outputChannelCount: Int
    let supportsInputVolume: Bool
    let supportsInputMute: Bool
    let supportsOutputVolume: Bool
    let supportsOutputMute: Bool

    var transportBadge: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Dahili"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "Sanal"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
        default: return "Harici"
        }
    }

    var systemIcon: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return isInput ? "laptopcomputer" : "speaker.wave.2.fill"
        case kAudioDeviceTransportTypeUSB: return isInput ? "mic.badge.plus" : "headphones"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "airpodspro"
        default: return isInput ? "mic.fill" : "hifispeaker.fill"
        }
    }
}

/// CoreAudio property listener kayıtlarını ve temizliğini yöneten yardımcı sınıf
private final class CoreAudioListenerRegistry {
    private struct RegisteredListener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    let queue = DispatchQueue(label: "com.izhar.sesduzenleyici.coreaudio.listeners")
    private var systemListeners: [RegisteredListener] = []
    private var deviceListeners: [RegisteredListener] = []
    private var observedInputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var observedOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    func installSystemListeners(onEvent: @escaping @Sendable () -> Void) {
        removeSystemListeners()

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]

        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                onEvent()
            }
            if AudioObjectAddPropertyListenerBlock(systemObj, &address, queue, block) == noErr {
                systemListeners.append(RegisteredListener(objectID: systemObj, address: address, block: block))
            }
        }
    }

    func updateObservedDevices(
        inputDeviceID: AudioObjectID,
        outputDeviceID: AudioObjectID,
        onDeviceLevelEvent: @escaping @Sendable () -> Void,
        onDeviceTopologyEvent: @escaping @Sendable () -> Void
    ) {
        if observedInputDeviceID == inputDeviceID && observedOutputDeviceID == outputDeviceID && !deviceListeners.isEmpty {
            return
        }

        removeDeviceListeners()
        observedInputDeviceID = inputDeviceID
        observedOutputDeviceID = outputDeviceID

        if inputDeviceID != kAudioObjectUnknown {
            registerScopeListeners(
                deviceID: inputDeviceID,
                scope: kAudioObjectPropertyScopeInput,
                onLevelEvent: onDeviceLevelEvent,
                onTopologyEvent: onDeviceTopologyEvent
            )
        }

        if outputDeviceID != kAudioObjectUnknown {
            registerScopeListeners(
                deviceID: outputDeviceID,
                scope: kAudioObjectPropertyScopeOutput,
                onLevelEvent: onDeviceLevelEvent,
                onTopologyEvent: onDeviceTopologyEvent
            )
        }
    }

    private func registerScopeListeners(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        onLevelEvent: @escaping @Sendable () -> Void,
        onTopologyEvent: @escaping @Sendable () -> Void
    ) {
        let levelAddresses: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: kAudioObjectPropertyElementWildcard
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: kAudioObjectPropertyElementWildcard
            )
        ]

        for var addr in levelAddresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                onLevelEvent()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block) == noErr {
                deviceListeners.append(RegisteredListener(objectID: deviceID, address: addr, block: block))
            }
        }

        let topologyAddresses: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: scope,
                mElement: kAudioObjectPropertyElementWildcard
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        for var addr in topologyAddresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                onTopologyEvent()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block) == noErr {
                deviceListeners.append(RegisteredListener(objectID: deviceID, address: addr, block: block))
            }
        }
    }

    func removeDeviceListeners() {
        for var entry in deviceListeners {
            _ = AudioObjectRemovePropertyListenerBlock(entry.objectID, &entry.address, queue, entry.block)
        }
        deviceListeners.removeAll()
        observedInputDeviceID = kAudioObjectUnknown
        observedOutputDeviceID = kAudioObjectUnknown
    }

    func removeSystemListeners() {
        for var entry in systemListeners {
            _ = AudioObjectRemovePropertyListenerBlock(entry.objectID, &entry.address, queue, entry.block)
        }
        systemListeners.removeAll()
    }

    func removeAllListeners() {
        removeDeviceListeners()
        removeSystemListeners()
    }
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    private enum MuteReadState: Equatable {
        case muted
        case unmuted
        case partial
        case unreadable
    }

    private struct ControlWriteOutcome {
        let status: OSStatus
        let failedChannels: [UInt32]
        let totalTargetChannels: Int

        var isSuccess: Bool {
            status == noErr && failedChannels.isEmpty
        }
    }

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var defaultInputDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var defaultOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    // Donanımdan geri okunan (doğrulanmış) gerçek değerler
    @Published private(set) var inputVolume: Float = 1.0
    @Published private(set) var isInputMuted: Bool = false
    @Published private(set) var outputVolume: Float = 1.0
    @Published private(set) var isOutputMuted: Bool = false

    // Kullanıcı tarafından son istenen ve doğrulama bekleyen durumlar
    @Published private(set) var requestedInputVolume: Float?
    @Published private(set) var requestedInputMute: Bool?
    @Published private(set) var isInputOperationPending: Bool = false

    @Published private(set) var requestedOutputVolume: Float?
    @Published private(set) var requestedOutputMute: Bool?
    @Published private(set) var isOutputOperationPending: Bool = false

    // Aktif cihazların doğrulanmış donanım kontrol yetenekleri
    @Published private(set) var canSetInputVolume: Bool = false
    @Published private(set) var hasHardwareInputMute: Bool = false
    @Published private(set) var canSetOutputVolume: Bool = false
    @Published private(set) var hasHardwareOutputMute: Bool = false

    // Hata ve donanım kısıt bildirimleri
    @Published var lastErrorMessage: String?
    @Published private(set) var inputSupportNotice: String?
    @Published private(set) var outputSupportNotice: String?

    /// Girişte MUTE yalnızca doğrulanmış donanım mute özelliğine dayanır; kazanç=0 susturma sayılmaz
    var canMuteInput: Bool {
        hasHardwareInputMute
    }

    /// Çıkışta MUTE yalnızca doğrulanmış donanım mute özelliğine dayanır
    var canMuteOutput: Bool {
        hasHardwareOutputMute
    }

    /// Giriş kazancının 0 seviyesinde olduğunu (ancak donanım mute olmadığını) belirtir
    var isInputGainAtMinimum: Bool {
        canSetInputVolume && !isInputMuted && inputVolume <= 0.001
    }

    /// Çıkış kazancının 0 seviyesinde olduğunu belirtir
    var isOutputGainAtMinimum: Bool {
        canSetOutputVolume && !isOutputMuted && outputVolume <= 0.001
    }

    var defaultOutputDeviceUID: String? {
        outputDevices.first(where: { $0.id == defaultOutputDeviceID })?.uid
    }

    var onDefaultOutputDeviceChanged: ((String?) -> Void)?

    // Yalnızca donanımdan doğrulanmış sıfır-üstü ses seviyelerini ve kanal dengesini saklayan hafıza
    private var savedInputVolumeByUID: [String: Float] = [:]
    private var savedOutputVolumeByUID: [String: Float] = [:]
    private var channelBalanceRatiosByScopeKey: [String: [UInt32: Float]] = [:]
    private var lastNotifiedOutputUID: String?

    private var inputVerifyTask: Task<Void, Never>?
    private var outputVerifyTask: Task<Void, Never>?

    private let listenerRegistry = CoreAudioListenerRegistry()

    init() {
        refreshAll()
        setupHardwareListeners()
    }

    deinit {
        inputVerifyTask?.cancel()
        outputVerifyTask?.cancel()
        listenerRegistry.removeAllListeners()
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func refreshAll() {
        let previousInputID = defaultInputDeviceID
        let previousOutputID = defaultOutputDeviceID

        let allDevices = fetchAllDevices()
        inputDevices = allDevices.filter {
            $0.isInput && !$0.name.hasPrefix("ArgonTap_") && !$0.uid.hasPrefix("com.argon.audiomixer.agg.")
        }
        outputDevices = allDevices.filter {
            $0.isOutput && !$0.name.hasPrefix("ArgonTap_") && !$0.uid.hasPrefix("com.argon.audiomixer.agg.")
        }

        defaultInputDeviceID = getDefaultDevice(scope: kAudioHardwarePropertyDefaultInputDevice)
        defaultOutputDeviceID = getDefaultDevice(scope: kAudioHardwarePropertyDefaultOutputDevice)

        if defaultInputDeviceID != previousInputID {
            cancelPendingInputVerification()
        }
        if defaultOutputDeviceID != previousOutputID {
            cancelPendingOutputVerification()
        }

        listenerRegistry.updateObservedDevices(
            inputDeviceID: defaultInputDeviceID,
            outputDeviceID: defaultOutputDeviceID,
            onDeviceLevelEvent: { [weak self] in
                Task { @MainActor in
                    self?.syncActiveDeviceLevels()
                }
            },
            onDeviceTopologyEvent: { [weak self] in
                Task { @MainActor in
                    self?.refreshAll()
                }
            }
        )

        syncActiveDeviceLevels()

        let currentOutUID = defaultOutputDeviceUID
        if currentOutUID != lastNotifiedOutputUID {
            lastNotifiedOutputUID = currentOutUID
            onDefaultOutputDeviceChanged?(currentOutUID)
        }
    }

    func syncActiveDeviceLevels() {
        // 1. Giriş (Mikrofon) donanım durumu okuma ve doğrulama
        if defaultInputDeviceID != kAudioObjectUnknown {
            let inputUID = deviceUID(for: defaultInputDeviceID, fallbackPrefix: "in")
            let volumeSupport = hasSettableVolumeControl(
                deviceID: defaultInputDeviceID,
                scope: kAudioObjectPropertyScopeInput
            )
            let muteSupport = hasSettableMuteControl(
                deviceID: defaultInputDeviceID,
                scope: kAudioObjectPropertyScopeInput
            )

            canSetInputVolume = volumeSupport
            hasHardwareInputMute = muteSupport

            let muteState = readDeviceMuteState(
                deviceID: defaultInputDeviceID,
                scope: kAudioObjectPropertyScopeInput
            )
            // Girişte MUTE yalnızca doğrulanmış donanım mute'u .muted ise true olur
            isInputMuted = muteSupport && (muteState == .muted)

            if let readVol = readDeviceVolume(deviceID: defaultInputDeviceID, scope: kAudioObjectPropertyScopeInput) {
                inputVolume = readVol
                // Yalnızca donanımdan doğrulanmış sıfır-üstü değeri restore hafızasına kaydet (alt sınır dayatmadan)
                if readVol > 0.0001 && !isInputMuted {
                    savedInputVolumeByUID[inputUID] = readVol
                }
            } else {
                inputVolume = 0.0
            }

            if !volumeSupport && !muteSupport {
                inputSupportNotice = "Seçili mikrofon donanımsal kazanç veya susturma kontrolünü desteklemiyor."
            } else if !muteSupport {
                inputSupportNotice = "Seçili mikrofon donanımsal susturma (Mute) desteklemiyor; yalnızca kazanç seviyesi ayarlanabilir."
            } else if !volumeSupport {
                inputSupportNotice = "Seçili mikrofon yalnızca donanımsal susturma (Mute) destekliyor; kazanç seviyesi sabit."
            } else if muteState == .partial {
                inputSupportNotice = "Mikrofon kanallarında kısmi susturma algılandı."
            } else {
                inputSupportNotice = nil
            }

            reconcilePendingInputIfSatisfied(currentMuteState: muteState)
        } else {
            cancelPendingInputVerification()
            canSetInputVolume = false
            hasHardwareInputMute = false
            inputVolume = 0.0
            isInputMuted = false
            inputSupportNotice = "Aktif mikrofon bulunamadı."
        }

        // 2. Çıkış (Hoparlör / Kulaklık) donanım durumu okuma ve doğrulama
        if defaultOutputDeviceID != kAudioObjectUnknown {
            let outputUID = deviceUID(for: defaultOutputDeviceID, fallbackPrefix: "out")
            let volumeSupport = hasSettableVolumeControl(
                deviceID: defaultOutputDeviceID,
                scope: kAudioObjectPropertyScopeOutput
            )
            let muteSupport = hasSettableMuteControl(
                deviceID: defaultOutputDeviceID,
                scope: kAudioObjectPropertyScopeOutput
            )

            canSetOutputVolume = volumeSupport
            hasHardwareOutputMute = muteSupport

            let muteState = readDeviceMuteState(
                deviceID: defaultOutputDeviceID,
                scope: kAudioObjectPropertyScopeOutput
            )
            isOutputMuted = muteSupport && (muteState == .muted)

            if let readVol = readDeviceVolume(deviceID: defaultOutputDeviceID, scope: kAudioObjectPropertyScopeOutput) {
                outputVolume = readVol
                if readVol > 0.0001 && !isOutputMuted {
                    savedOutputVolumeByUID[outputUID] = readVol
                }
            } else {
                outputVolume = 0.0
            }

            if !volumeSupport && !muteSupport {
                outputSupportNotice = "Seçili çıkış aygıtı (ör. HDMI/DisplayPort) donanımsal ses kontrolünü desteklemiyor."
            } else if !muteSupport {
                outputSupportNotice = "Seçili çıkış aygıtı donanımsal susturma (Mute) desteklemiyor; yalnızca ses seviyesi ayarlanabilir."
            } else if !volumeSupport {
                outputSupportNotice = "Seçili çıkış aygıtı yalnızca donanımsal susturma (Mute) destekliyor."
            } else if muteState == .partial {
                outputSupportNotice = "Çıkış kanallarında kısmi susturma algılandı."
            } else {
                outputSupportNotice = nil
            }

            reconcilePendingOutputIfSatisfied(currentMuteState: muteState)
        } else {
            cancelPendingOutputVerification()
            canSetOutputVolume = false
            hasHardwareOutputMute = false
            outputVolume = 0.0
            isOutputMuted = false
            outputSupportNotice = "Aktif çıkış aygıtı bulunamadı."
        }
    }

    // MARK: - Giriş / Çıkış Aygıtı Seçimi

    func selectInputDevice(_ device: AudioDevice) {
        let status = setDefaultDevice(device.id, property: kAudioHardwarePropertyDefaultInputDevice)
        if status != noErr {
            lastErrorMessage = "Varsayılan mikrofon değiştirilemedi (CoreAudio hata kodu: \(status))."
            refreshAll()
            return
        }
        refreshAll()
        if defaultInputDeviceID == device.id {
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Mikrofon seçim komutu gönderildi (noErr) ancak sistem varsayılan aygıtı değiştirmedi."
        }
    }

    func selectOutputDevice(_ device: AudioDevice) {
        let status = setDefaultDevice(device.id, property: kAudioHardwarePropertyDefaultOutputDevice)
        if status != noErr {
            lastErrorMessage = "Varsayılan çıkış aygıtı değiştirilemedi (CoreAudio hata kodu: \(status))."
            refreshAll()
            return
        }
        refreshAll()
        if defaultOutputDeviceID == device.id {
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Çıkış aygıtı seçim komutu gönderildi (noErr) ancak sistem varsayılan aygıtı değiştirmedi."
        }
    }

    // MARK: - Ses Seviyesi ve Mute Kontrolleri

    func setInputVolume(_ value: Float) {
        guard defaultInputDeviceID != kAudioObjectUnknown else {
            lastErrorMessage = "Aktif bir giriş aygıtı seçili değil."
            return
        }
        guard canSetInputVolume else {
            lastErrorMessage = "Bu mikrofon donanımsal kazanç seviyesi ayarını desteklemiyor."
            syncActiveDeviceLevels()
            return
        }

        let clamped = max(0.0, min(1.0, value))
        var requiredUnmute: Bool? = nil

        // Mikrofon donanımsal olarak susturulmuşsa ve kullanıcı seviyeyi açıyorsa önce donanım mute'u kaldır
        if clamped > 0.001 && isInputMuted && hasHardwareInputMute {
            let unmuteOutcome = setDeviceHardwareMute(
                deviceID: defaultInputDeviceID,
                scope: kAudioObjectPropertyScopeInput,
                mute: false
            )
            if !unmuteOutcome.isSuccess {
                syncActiveDeviceLevels()
                lastErrorMessage = formatWriteError(
                    prefix: "Mikrofon seviyesi değiştirilirken susturma kaldırılamadı",
                    outcome: unmuteOutcome
                )
                return
            }
            requiredUnmute = false
        }

        let volumeOutcome = writeDeviceVolume(
            deviceID: defaultInputDeviceID,
            scope: kAudioObjectPropertyScopeInput,
            volume: clamped
        )
        if !volumeOutcome.isSuccess {
            syncActiveDeviceLevels()
            lastErrorMessage = formatWriteError(
                prefix: "Mikrofon kazanç seviyesi uygulanamadı",
                outcome: volumeOutcome
            )
            return
        }

        beginInputVerification(expectedVolume: clamped, expectedMute: requiredUnmute)
    }

    func toggleInputMute(forceValue: Bool? = nil) {
        guard defaultInputDeviceID != kAudioObjectUnknown else {
            lastErrorMessage = "Aktif bir giriş aygıtı seçili değil."
            return
        }
        guard canMuteInput else {
            lastErrorMessage = "Seçili mikrofon donanımsal susturma (Mute) özelliğini desteklemiyor."
            syncActiveDeviceLevels()
            return
        }

        let targetMute = forceValue ?? !isInputMuted
        let inputUID = deviceUID(for: defaultInputDeviceID, fallbackPrefix: "in")

        if targetMute {
            if let confirmedVol = readDeviceVolume(deviceID: defaultInputDeviceID, scope: kAudioObjectPropertyScopeInput),
               confirmedVol > 0.0001 {
                savedInputVolumeByUID[inputUID] = confirmedVol
            }

            let muteOutcome = setDeviceHardwareMute(
                deviceID: defaultInputDeviceID,
                scope: kAudioObjectPropertyScopeInput,
                mute: true
            )
            if !muteOutcome.isSuccess {
                syncActiveDeviceLevels()
                lastErrorMessage = formatWriteError(
                    prefix: "Mikrofon donanımsal olarak susturulamadı",
                    outcome: muteOutcome
                )
                return
            }

            beginInputVerification(expectedVolume: nil, expectedMute: true)
        } else {
            let muteOutcome = setDeviceHardwareMute(
                deviceID: defaultInputDeviceID,
                scope: kAudioObjectPropertyScopeInput,
                mute: false
            )
            if !muteOutcome.isSuccess {
                syncActiveDeviceLevels()
                lastErrorMessage = formatWriteError(
                    prefix: "Mikrofon susturma durumu kaldırılamadı",
                    outcome: muteOutcome
                )
                return
            }

            var expectedRestoredVolume: Float? = nil
            if canSetInputVolume,
               let currentVol = readDeviceVolume(deviceID: defaultInputDeviceID, scope: kAudioObjectPropertyScopeInput),
               currentVol <= 0.0001,
               let savedVol = savedInputVolumeByUID[inputUID],
               savedVol > 0.0001 {
                let volOutcome = writeDeviceVolume(
                    deviceID: defaultInputDeviceID,
                    scope: kAudioObjectPropertyScopeInput,
                    volume: savedVol
                )
                if !volOutcome.isSuccess {
                    syncActiveDeviceLevels()
                    lastErrorMessage = formatWriteError(
                        prefix: "Mikrofon susturması açıldı ancak önceki kazanç seviyesi geri yüklenemedi",
                        outcome: volOutcome
                    )
                    return
                }
                expectedRestoredVolume = savedVol
            }

            beginInputVerification(expectedVolume: expectedRestoredVolume, expectedMute: false)
        }
    }

    func setOutputVolume(_ value: Float) {
        guard defaultOutputDeviceID != kAudioObjectUnknown else {
            lastErrorMessage = "Aktif bir çıkış aygıtı seçili değil."
            return
        }
        guard canSetOutputVolume else {
            lastErrorMessage = "Bu çıkış aygıtı donanımsal ses seviyesi ayarını desteklemiyor."
            syncActiveDeviceLevels()
            return
        }

        let clamped = max(0.0, min(1.0, value))
        var requiredUnmute: Bool? = nil

        if clamped > 0.001 && isOutputMuted && hasHardwareOutputMute {
            let unmuteOutcome = setDeviceHardwareMute(
                deviceID: defaultOutputDeviceID,
                scope: kAudioObjectPropertyScopeOutput,
                mute: false
            )
            if !unmuteOutcome.isSuccess {
                syncActiveDeviceLevels()
                lastErrorMessage = formatWriteError(
                    prefix: "Çıkış seviyesi değiştirilirken susturma kaldırılamadı",
                    outcome: unmuteOutcome
                )
                return
            }
            requiredUnmute = false
        }

        let volumeOutcome = writeDeviceVolume(
            deviceID: defaultOutputDeviceID,
            scope: kAudioObjectPropertyScopeOutput,
            volume: clamped
        )
        if !volumeOutcome.isSuccess {
            syncActiveDeviceLevels()
            lastErrorMessage = formatWriteError(
                prefix: "Çıkış ses seviyesi uygulanamadı",
                outcome: volumeOutcome
            )
            return
        }

        beginOutputVerification(expectedVolume: clamped, expectedMute: requiredUnmute)
    }

    func toggleOutputMute(forceValue: Bool? = nil) {
        guard defaultOutputDeviceID != kAudioObjectUnknown else {
            lastErrorMessage = "Aktif bir çıkış aygıtı seçili değil."
            return
        }
        guard canMuteOutput else {
            lastErrorMessage = "Seçili çıkış aygıtı donanımsal susturma (Mute) özelliğini desteklemiyor."
            syncActiveDeviceLevels()
            return
        }

        let targetMute = forceValue ?? !isOutputMuted
        let outputUID = deviceUID(for: defaultOutputDeviceID, fallbackPrefix: "out")

        if targetMute {
            if let confirmedVol = readDeviceVolume(deviceID: defaultOutputDeviceID, scope: kAudioObjectPropertyScopeOutput),
               confirmedVol > 0.0001 {
                savedOutputVolumeByUID[outputUID] = confirmedVol
            }

            let muteOutcome = setDeviceHardwareMute(
                deviceID: defaultOutputDeviceID,
                scope: kAudioObjectPropertyScopeOutput,
                mute: true
            )
            if !muteOutcome.isSuccess {
                syncActiveDeviceLevels()
                lastErrorMessage = formatWriteError(
                    prefix: "Çıkış sesi donanımsal olarak susturulamadı",
                    outcome: muteOutcome
                )
                return
            }

            beginOutputVerification(expectedVolume: nil, expectedMute: true)
        } else {
            let muteOutcome = setDeviceHardwareMute(
                deviceID: defaultOutputDeviceID,
                scope: kAudioObjectPropertyScopeOutput,
                mute: false
            )
            if !muteOutcome.isSuccess {
                syncActiveDeviceLevels()
                lastErrorMessage = formatWriteError(
                    prefix: "Çıkış susturma durumu kaldırılamadı",
                    outcome: muteOutcome
                )
                return
            }

            var expectedRestoredVolume: Float? = nil
            if canSetOutputVolume,
               let currentVol = readDeviceVolume(deviceID: defaultOutputDeviceID, scope: kAudioObjectPropertyScopeOutput),
               currentVol <= 0.0001,
               let savedVol = savedOutputVolumeByUID[outputUID],
               savedVol > 0.0001 {
                let volOutcome = writeDeviceVolume(
                    deviceID: defaultOutputDeviceID,
                    scope: kAudioObjectPropertyScopeOutput,
                    volume: savedVol
                )
                if !volOutcome.isSuccess {
                    syncActiveDeviceLevels()
                    lastErrorMessage = formatWriteError(
                        prefix: "Çıkış susturması açıldı ancak önceki ses seviyesi geri yüklenemedi",
                        outcome: volOutcome
                    )
                    return
                }
                expectedRestoredVolume = savedVol
            }

            beginOutputVerification(expectedVolume: expectedRestoredVolume, expectedMute: false)
        }
    }

    // MARK: - Asenkron Donanım Doğrulama (Readback Confirmation)

    private func beginInputVerification(expectedVolume: Float?, expectedMute: Bool?) {
        inputVerifyTask?.cancel()
        requestedInputVolume = expectedVolume
        requestedInputMute = expectedMute
        isInputOperationPending = true

        // Önce senkron geri-okuma ile hemen doğrulandı mı kontrol et
        syncActiveDeviceLevels()
        guard isInputOperationPending else { return }

        // Sürücü değişikliği asenkron uyguluyorsa kısa pencere sonunda tekrar doğrula
        inputVerifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.syncActiveDeviceLevels()
            if self.isInputOperationPending {
                let expDesc = self.describeExpected(volume: self.requestedInputVolume, mute: self.requestedInputMute)
                self.cancelPendingInputVerification()
                self.lastErrorMessage = "Mikrofon komutu iletildi (noErr) ancak donanım durumu doğrulamadı (\(expDesc))."
            }
        }
    }

    private func reconcilePendingInputIfSatisfied(currentMuteState: MuteReadState) {
        guard isInputOperationPending else { return }

        var volumeMatches = true
        if let expVol = requestedInputVolume {
            if let actualVol = readDeviceVolume(deviceID: defaultInputDeviceID, scope: kAudioObjectPropertyScopeInput) {
                volumeMatches = abs(actualVol - expVol) <= 0.05
            } else {
                volumeMatches = false
            }
        }

        var muteMatches = true
        if let expMute = requestedInputMute {
            let expectedState: MuteReadState = expMute ? .muted : .unmuted
            muteMatches = (currentMuteState == expectedState)
        }

        if volumeMatches && muteMatches {
            cancelPendingInputVerification()
            lastErrorMessage = nil
        }
    }

    private func cancelPendingInputVerification() {
        inputVerifyTask?.cancel()
        inputVerifyTask = nil
        requestedInputVolume = nil
        requestedInputMute = nil
        isInputOperationPending = false
    }

    private func beginOutputVerification(expectedVolume: Float?, expectedMute: Bool?) {
        outputVerifyTask?.cancel()
        requestedOutputVolume = expectedVolume
        requestedOutputMute = expectedMute
        isOutputOperationPending = true

        syncActiveDeviceLevels()
        guard isOutputOperationPending else { return }

        outputVerifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.syncActiveDeviceLevels()
            if self.isOutputOperationPending {
                let expDesc = self.describeExpected(volume: self.requestedOutputVolume, mute: self.requestedOutputMute)
                self.cancelPendingOutputVerification()
                self.lastErrorMessage = "Çıkış komutu iletildi (noErr) ancak donanım durumu doğrulamadı (\(expDesc))."
            }
        }
    }

    private func reconcilePendingOutputIfSatisfied(currentMuteState: MuteReadState) {
        guard isOutputOperationPending else { return }

        var volumeMatches = true
        if let expVol = requestedOutputVolume {
            if let actualVol = readDeviceVolume(deviceID: defaultOutputDeviceID, scope: kAudioObjectPropertyScopeOutput) {
                volumeMatches = abs(actualVol - expVol) <= 0.05
            } else {
                volumeMatches = false
            }
        }

        var muteMatches = true
        if let expMute = requestedOutputMute {
            let expectedState: MuteReadState = expMute ? .muted : .unmuted
            muteMatches = (currentMuteState == expectedState)
        }

        if volumeMatches && muteMatches {
            cancelPendingOutputVerification()
            lastErrorMessage = nil
        }
    }

    private func cancelPendingOutputVerification() {
        outputVerifyTask?.cancel()
        outputVerifyTask = nil
        requestedOutputVolume = nil
        requestedOutputMute = nil
        isOutputOperationPending = false
    }

    private func describeExpected(volume: Float?, mute: Bool?) -> String {
        var parts: [String] = []
        if let mute = mute {
            parts.append(mute ? "Susturma: Açık" : "Susturma: Kapalı")
        }
        if let volume = volume {
            parts.append("Hedef Seviye: %\(Int(round(volume * 100)))")
        }
        return parts.isEmpty ? "Doğrulanamadı" : parts.joined(separator: ", ")
    }

    private func formatWriteError(prefix: String, outcome: ControlWriteOutcome) -> String {
        if !outcome.failedChannels.isEmpty {
            let chList = outcome.failedChannels.map(String.init).joined(separator: ", ")
            return "\(prefix): Kanal [\(chList)] yazımı başarısız oldu (CoreAudio hata kodu: \(outcome.status))."
        }
        return "\(prefix) (CoreAudio hata kodu: \(outcome.status))."
    }

    // MARK: - CoreAudio Low-Level Sorgular ve Doğrulanmış Yetenek Tespiti

    private func deviceUID(for deviceID: AudioObjectID, fallbackPrefix: String) -> String {
        if let uid = getStringProperty(id: deviceID, selector: kAudioDevicePropertyDeviceUID) {
            return uid
        }
        return "\(fallbackPrefix)_\(deviceID)"
    }

    private func fetchAllDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioDevice? in
            guard let name = getStringProperty(id: id, selector: kAudioObjectPropertyName),
                  let uid = getStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            let transport = getUInt32Property(id: id, selector: kAudioDevicePropertyTransportType) ?? 0
            let inChannels = channelCount(deviceID: id, scope: kAudioObjectPropertyScopeInput)
            let outChannels = channelCount(deviceID: id, scope: kAudioObjectPropertyScopeOutput)

            guard inChannels > 0 || outChannels > 0 else { return nil }

            let supInVol = inChannels > 0 && hasSettableVolumeControl(deviceID: id, scope: kAudioObjectPropertyScopeInput)
            let supInMute = inChannels > 0 && hasSettableMuteControl(deviceID: id, scope: kAudioObjectPropertyScopeInput)
            let supOutVol = outChannels > 0 && hasSettableVolumeControl(deviceID: id, scope: kAudioObjectPropertyScopeOutput)
            let supOutMute = outChannels > 0 && hasSettableMuteControl(deviceID: id, scope: kAudioObjectPropertyScopeOutput)

            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                transportType: transport,
                isInput: inChannels > 0,
                isOutput: outChannels > 0,
                inputChannelCount: inChannels,
                outputChannelCount: outChannels,
                supportsInputVolume: supInVol,
                supportsInputMute: supInMute,
                supportsOutputVolume: supOutVol,
                supportsOutputMute: supOutMute
            )
        }
    }

    private func channelCount(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func candidateChannelElements(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
        let totalChannels = channelCount(deviceID: deviceID, scope: scope)
        guard totalChannels > 0 else { return [] }
        return (1...UInt32(totalChannels)).map { $0 }
    }

    private func isPropertySettable(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func readSingleFloatProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var val: Float32 = 0.0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &val) == noErr else {
            return nil
        }
        return max(0.0, min(1.0, val))
    }

    private func readSingleMuteProperty(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    /// Tam ses seviyesi kontrol yeteneği: Ana element (Virtual veya Main) ya da kapsamdaki TÜM kanallar hem okunabilir hem yazılabilir olmalıdır
    private func hasSettableVolumeControl(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        let channels = candidateChannelElements(deviceID: deviceID, scope: scope)
        guard !channels.isEmpty else { return false }

        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), readSingleFloatProperty(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) != nil {
            return true
        }

        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), readSingleFloatProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) != nil {
            return true
        }

        return channels.allSatisfy { ch in
            isPropertySettable(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: ch
            ) && readSingleFloatProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: ch
            ) != nil
        }
    }

    /// Tam donanım mute yeteneği: Ana element (Main=0) ya da kapsamdaki TÜM kanallar hem okunabilir hem yazılabilir olmalıdır
    private func hasSettableMuteControl(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        let channels = candidateChannelElements(deviceID: deviceID, scope: scope)
        guard !channels.isEmpty else { return false }

        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), readSingleMuteProperty(
            deviceID: deviceID,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) != nil {
            return true
        }

        return channels.allSatisfy { ch in
            isPropertySettable(
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: scope,
                element: ch
            ) && readSingleMuteProperty(
                deviceID: deviceID,
                scope: scope,
                element: ch
            ) != nil
        }
    }

    private func getDefaultDevice(scope: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: scope,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr else {
            return kAudioObjectUnknown
        }
        return deviceID
    }

    private func setDefaultDevice(_ deviceID: AudioObjectID, property: AudioObjectPropertySelector) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: property,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = deviceID
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &mutableID
        )
    }

    private func readDeviceVolume(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        // 1. VirtualMainVolume (Eğer yazılabilir kontrol yoluysa veya mevcutsa)
        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), let v = readSingleFloatProperty(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) {
            return v
        }

        // 2. Main Element (0) VolumeScalar
        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), let v = readSingleFloatProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) {
            return v
        }

        // 3. Gerçek kanalların (1...N) tamamını oku ve kanal dengesini güncelle
        let channels = candidateChannelElements(deviceID: deviceID, scope: scope)
        guard !channels.isEmpty else { return nil }

        var channelValues: [UInt32: Float] = [:]
        for ch in channels {
            if let chVol = readSingleFloatProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: ch
            ) {
                channelValues[ch] = chVol
            }
        }

        // Eğer kanalların tamamı okunamadıysa salt-okunur VirtualMainVolume veya Main fallback dene
        if channelValues.count < channels.count {
            if let v = readSingleFloatProperty(
                deviceID: deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            ) {
                return v
            }
            if let v = readSingleFloatProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            ) {
                return v
            }
            return nil
        }

        guard let maxVol = channelValues.values.max() else {
            return nil
        }

        if maxVol > 0.0001 {
            let scopeKey = "\(deviceUID(for: deviceID, fallbackPrefix: "dev"))_\(scope)"
            var ratios: [UInt32: Float] = [:]
            for (ch, val) in channelValues {
                ratios[ch] = max(0.0, min(1.0, val / maxVol))
            }
            channelBalanceRatiosByScopeKey[scopeKey] = ratios
        }

        return maxVol
    }

    /// Yalnızca tek bir doğrulanmış kontrol yolunu kullanır; çok kanallı yazılımda herhangi bir kanal hata verirse kısmi hatayı gizlemez
    private func writeDeviceVolume(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        volume: Float
    ) -> ControlWriteOutcome {
        var mutableVol = Float32(max(0.0, min(1.0, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)

        // Yol 1: VirtualMainVolume
        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), readSingleFloatProperty(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) != nil {
            var virtualAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(deviceID, &virtualAddress, 0, nil, size, &mutableVol)
            return ControlWriteOutcome(status: status, failedChannels: [], totalTargetChannels: 1)
        }

        // Yol 2: Main Element (0) VolumeScalar
        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), readSingleFloatProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) != nil {
            var mainAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(deviceID, &mainAddress, 0, nil, size, &mutableVol)
            return ControlWriteOutcome(status: status, failedChannels: [], totalTargetChannels: 1)
        }

        // Yol 3: Kapsamdaki tüm gerçek kanallar (1...N)
        let channels = candidateChannelElements(deviceID: deviceID, scope: scope)
        guard !channels.isEmpty else {
            return ControlWriteOutcome(
                status: kAudioHardwareUnsupportedOperationError,
                failedChannels: [],
                totalTargetChannels: 0
            )
        }

        // Mevcut kanal dengesini koru
        _ = readDeviceVolume(deviceID: deviceID, scope: scope)
        let scopeKey = "\(deviceUID(for: deviceID, fallbackPrefix: "dev"))_\(scope)"
        let savedRatios = channelBalanceRatiosByScopeKey[scopeKey]

        var failedChannels: [UInt32] = []
        var firstErrorStatus: OSStatus = noErr

        for ch in channels {
            guard isPropertySettable(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: ch
            ) else {
                failedChannels.append(ch)
                if firstErrorStatus == noErr {
                    firstErrorStatus = kAudioHardwareUnsupportedOperationError
                }
                continue
            }

            let ratio = savedRatios?[ch] ?? 1.0
            var channelTarget = Float32(max(0.0, min(1.0, volume * ratio)))
            var chAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: ch
            )
            let st = AudioObjectSetPropertyData(deviceID, &chAddress, 0, nil, size, &channelTarget)
            if st != noErr {
                failedChannels.append(ch)
                if firstErrorStatus == noErr {
                    firstErrorStatus = st
                }
            }
        }

        let finalStatus = failedChannels.isEmpty ? noErr : (firstErrorStatus != noErr ? firstErrorStatus : kAudioHardwareUnspecifiedError)
        return ControlWriteOutcome(
            status: finalStatus,
            failedChannels: failedChannels,
            totalTargetChannels: channels.count
        )
    }

    private func readDeviceMuteState(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> MuteReadState {
        // 1. Main Element (0) yazılabilir/okunabilir kontrol yoluysa onu oku
        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), let mainMuted = readSingleMuteProperty(
            deviceID: deviceID,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) {
            return mainMuted ? .muted : .unmuted
        }

        // 2. Tüm gerçek kanalları (1...N) sorgula
        let channels = candidateChannelElements(deviceID: deviceID, scope: scope)
        guard !channels.isEmpty else { return .unreadable }

        var states: [Bool] = []
        for ch in channels {
            guard let chMuted = readSingleMuteProperty(deviceID: deviceID, scope: scope, element: ch) else {
                // Herhangi bir kanal okunamıyorsa salt-okunur main element varsa ona bak, yoksa .unreadable döndür
                if let fallbackMain = readSingleMuteProperty(
                    deviceID: deviceID,
                    scope: scope,
                    element: kAudioObjectPropertyElementMain
                ) {
                    return fallbackMain ? .muted : .unmuted
                }
                return .unreadable
            }
            states.append(chMuted)
        }

        if states.allSatisfy({ $0 }) {
            return .muted
        } else if states.allSatisfy({ !$0 }) {
            return .unmuted
        } else {
            return .partial
        }
    }

    /// Yalnızca ana element veya tüm kanallar üzerinden donanım mute yazar; kısmi kanal başarısızlığını açık hata olarak döndürür
    private func setDeviceHardwareMute(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        mute: Bool
    ) -> ControlWriteOutcome {
        var mutableMute: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)

        // Yol 1: Main Element (0) Mute
        if isPropertySettable(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ), readSingleMuteProperty(
            deviceID: deviceID,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) != nil {
            var mainAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(deviceID, &mainAddress, 0, nil, size, &mutableMute)
            return ControlWriteOutcome(status: status, failedChannels: [], totalTargetChannels: 1)
        }

        // Yol 2: Kapsamdaki tüm gerçek kanallar (1...N)
        let channels = candidateChannelElements(deviceID: deviceID, scope: scope)
        guard !channels.isEmpty else {
            return ControlWriteOutcome(
                status: kAudioHardwareUnsupportedOperationError,
                failedChannels: [],
                totalTargetChannels: 0
            )
        }

        var failedChannels: [UInt32] = []
        var firstErrorStatus: OSStatus = noErr

        for ch in channels {
            guard isPropertySettable(
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute,
                scope: scope,
                element: ch
            ), readSingleMuteProperty(deviceID: deviceID, scope: scope, element: ch) != nil else {
                failedChannels.append(ch)
                if firstErrorStatus == noErr {
                    firstErrorStatus = kAudioHardwareUnsupportedOperationError
                }
                continue
            }

            var chAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: ch
            )
            let st = AudioObjectSetPropertyData(deviceID, &chAddress, 0, nil, size, &mutableMute)
            if st != noErr {
                failedChannels.append(ch)
                if firstErrorStatus == noErr {
                    firstErrorStatus = st
                }
            }
        }

        let finalStatus = failedChannels.isEmpty ? noErr : (firstErrorStatus != noErr ? firstErrorStatus : kAudioHardwareUnspecifiedError)
        return ControlWriteOutcome(
            status: finalStatus,
            failedChannels: failedChannels,
            totalTargetChannels: channels.count
        )
    }

    private func getStringProperty(id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanagedString)
        guard status == noErr, let cfStr = unmanagedString?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    private func getUInt32Property(id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func setupHardwareListeners() {
        listenerRegistry.installSystemListeners { [weak self] in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }
}
