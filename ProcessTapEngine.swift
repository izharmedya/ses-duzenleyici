import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Darwin
import Foundation

struct AudioAppProcess: Identifiable, Hashable {
    let id: String
    var processObjectIDs: [AudioObjectID]
    let pid: pid_t
    let name: String
    let icon: NSImage
    var isPlayingAudio: Bool

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func == (lhs: AudioAppProcess, rhs: AudioAppProcess) -> Bool {
        lhs.id == rhs.id && lhs.processObjectIDs == rhs.processObjectIDs && lhs.isPlayingAudio == rhs.isPlayingAudio
    }
}

/// A process tap routed back to the selected physical output through a private aggregate device.
/// The real-time callback calls only the C bridge; it does not enter Swift or allocate memory.
private final class ActiveProcessTapSession {
    let processIDs: [AudioObjectID]
    let outputUID: String

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var state: UnsafeMutablePointer<RTTapSharedState>?

    init?(processIDs: [AudioObjectID], outputUID: String, gain: Float, muted: Bool) {
        self.processIDs = processIDs
        self.outputUID = outputUID
        guard !processIDs.isEmpty, start(gain: gain, muted: muted) else {
            stop()
            return nil
        }
    }

    deinit { stop() }

    func setGain(_ gain: Float) {
        guard let state else { return }
        rt_tap_state_set_gain(state, gain)
    }

    func setMuted(_ muted: Bool) {
        guard let state else { return }
        rt_tap_state_set_muted(state, muted)
    }

    var callbackCount: UInt32 {
        guard let state else { return 0 }
        return rt_tap_state_get_total_callbacks(state)
    }

    var nonSilentCallbackCount: UInt32 {
        guard let state else { return 0 }
        return rt_tap_state_get_nonsilent_callbacks(state)
    }

    private func start(gain: Float, muted: Bool) -> Bool {
        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = tapUUID
        description.name = "SesDüzenleyici-\(tapUUID.uuidString.prefix(8))"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else { return false }
        tapID = newTapID

        guard let tapUID = readStringProperty(objectID: tapID, selector: kAudioTapPropertyUID) else {
            return false
        }

        let aggregateUID = "com.izhar.sesduzenleyici.aggregate.\(tapUUID.uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ses Düzenleyici Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: false
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != kAudioObjectUnknown else { return false }
        aggregateID = newAggregateID

        guard let routing = resolveRouting(aggregateID: aggregateID, outputUID: outputUID) else { return false }

        guard let sharedState = rt_tap_state_create(gain, muted) else { return false }
        state = sharedState
        rt_tap_state_configure_routing(
            sharedState,
            routing.inputLeft.buffer, routing.inputLeft.channel,
            routing.inputRight.buffer, routing.inputRight.channel,
            routing.outputLeft.buffer, routing.outputLeft.channel,
            routing.outputRight.buffer, routing.outputRight.channel,
            routing.isStereoOutput
        )

        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
            rt_process_tap_buffers(sharedState, inputData, outputData)
        }
        guard ioStatus == noErr, let newIOProcID else { return false }
        ioProcID = newIOProcID

        rt_tap_state_set_active(sharedState, true)
        guard AudioDeviceStart(aggregateID, newIOProcID) == noErr else {
            rt_tap_state_set_active(sharedState, false)
            return false
        }
        return true
    }

    private struct ChannelRoute {
        let buffer: Int32
        let channel: Int32
    }

    private struct Routing {
        let inputLeft: ChannelRoute
        let inputRight: ChannelRoute
        let outputLeft: ChannelRoute
        let outputRight: ChannelRoute
        let isStereoOutput: Bool
    }

    /// Resolve streams from HAL metadata and fail closed if the tap stream cannot be distinguished
    /// from physical input streams. This prevents a duplex headset microphone entering the mix.
    private func resolveRouting(aggregateID: AudioObjectID, outputUID: String) -> Routing? {
        guard let tapFormat = readStreamFormat(objectID: tapID, selector: kAudioTapPropertyFormat),
              isSupportedFloatFormat(tapFormat),
              let physicalOutputID = findDeviceID(uid: outputUID),
              let aggregateInputStreams = readStreamIDs(deviceID: aggregateID, scope: kAudioDevicePropertyScopeInput),
              let physicalInputStreams = readStreamIDs(deviceID: physicalOutputID, scope: kAudioDevicePropertyScopeInput),
              let aggregateInputBuffers = readStreamConfiguration(deviceID: aggregateID, scope: kAudioDevicePropertyScopeInput),
              let physicalInputBuffers = readStreamConfiguration(deviceID: physicalOutputID, scope: kAudioDevicePropertyScopeInput),
              aggregateInputStreams.count == aggregateInputBuffers.count,
              physicalInputStreams.count == physicalInputBuffers.count,
              aggregateInputStreams.count > physicalInputStreams.count else {
            return nil
        }

        // The aggregate is created with one physical subdevice followed by one tap. Its input
        // streams therefore consist of the physical device's streams followed by the tap stream.
        // Require exactly one matching tap stream rather than guessing from the last buffer.
        let tapStreamIndices = Array(physicalInputStreams.count..<aggregateInputStreams.count)
        let matchingTapIndices = tapStreamIndices.filter { index in
            guard let format = readStreamFormat(objectID: aggregateInputStreams[index], selector: kAudioStreamPropertyVirtualFormat) else {
                return false
            }
            return isSupportedFloatFormat(format) &&
                format.mChannelsPerFrame == tapFormat.mChannelsPerFrame &&
                abs(format.mSampleRate - tapFormat.mSampleRate) < 1.0
        }
        guard matchingTapIndices.count == 1,
              let tapIndex = matchingTapIndices.first,
              tapIndex < aggregateInputBuffers.count else {
            return nil
        }

        let tapChannels = Int(aggregateInputBuffers[tapIndex])
        guard tapChannels == Int(tapFormat.mChannelsPerFrame), tapChannels > 0 else { return nil }
        let inputLeft = ChannelRoute(buffer: Int32(tapIndex), channel: 0)
        let inputRight = ChannelRoute(buffer: Int32(tapIndex), channel: tapChannels > 1 ? 1 : 0)

        guard let aggregateOutputStreams = readStreamIDs(deviceID: aggregateID, scope: kAudioDevicePropertyScopeOutput),
              let outputBuffers = readStreamConfiguration(deviceID: aggregateID, scope: kAudioDevicePropertyScopeOutput),
              aggregateOutputStreams.count == outputBuffers.count,
              !outputBuffers.isEmpty else {
            return nil
        }

        // A stacked=false aggregate sends one program stream to the output subdevice. Use its
        // first stereo pair (or mono channel) and leave all other output channels silent.
        let outputBuffer = outputBuffers.firstIndex(where: { $0 > 0 })
        guard let outputBuffer else { return nil }
        let outputChannels = Int(outputBuffers[outputBuffer])
        let left = ChannelRoute(buffer: Int32(outputBuffer), channel: 0)
        let right: ChannelRoute
        let stereo: Bool
        if outputChannels >= 2 {
            right = ChannelRoute(buffer: Int32(outputBuffer), channel: 1)
            stereo = true
        } else if outputBuffer + 1 < outputBuffers.count, outputBuffers[outputBuffer + 1] > 0 {
            right = ChannelRoute(buffer: Int32(outputBuffer + 1), channel: 0)
            stereo = true
        } else {
            right = left
            stereo = false
        }

        guard aggregateOutputStreams.indices.contains(outputBuffer),
              let outFormat = readStreamFormat(objectID: aggregateOutputStreams[outputBuffer], selector: kAudioStreamPropertyVirtualFormat),
              isSupportedFloatFormat(outFormat),
              aggregateInputStreams.indices.contains(tapIndex) else {
            return nil
        }
        if stereo, let rightFormatIndex = aggregateOutputStreams.indices.contains(outputBuffer + 1) ? outputBuffer + 1 : nil,
           right.buffer != left.buffer,
           let rightFormat = readStreamFormat(objectID: aggregateOutputStreams[rightFormatIndex], selector: kAudioStreamPropertyVirtualFormat),
           !isSupportedFloatFormat(rightFormat) {
            return nil
        }

        return Routing(
            inputLeft: inputLeft,
            inputRight: inputRight,
            outputLeft: left,
            outputRight: right,
            isStereoOutput: stereo
        )
    }

    private func stop() {
        if let state {
            rt_tap_state_set_active(state, false)
        }
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if let state {
            rt_tap_state_destroy(state)
            self.state = nil
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func readStreamIDs(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioStreamID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr,
              byteCount % UInt32(MemoryLayout<AudioStreamID>.size) == 0 else { return nil }
        guard byteCount > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioStreamID>.size)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        return status == noErr ? ids : nil
    }

    private func readStreamConfiguration(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr,
              byteCount >= UInt32(MemoryLayout<AudioBufferList>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, raw) == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }

    private func readStreamFormat(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var byteCount = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &format) == noErr else { return nil }
        return format
    }

    private func isSupportedFloatFormat(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0,
              format.mBytesPerFrame == UInt32(MemoryLayout<Float>.size) * format.mChannelsPerFrame,
              format.mBytesPerPacket == format.mBytesPerFrame else {
            return false
        }
        return true
    }

    private func readStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var byteCount = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, $0)
        }
        return status == noErr ? (value as String) : nil
    }

    private func findDeviceID(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0 else { return nil }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(systemID, &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        return deviceIDs.first { readStringProperty(objectID: $0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }
}

@MainActor
final class ProcessTapEngine: ObservableObject {
    @Published private(set) var processes: [AudioAppProcess] = []
    @Published var showOnlyActiveAudio = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var showCaptureSettingsAction = false
    @Published private(set) var volumes: [String: Float] = [:]
    @Published private(set) var muteStates: [String: Bool] = [:]

    private var outputDeviceUID: String?
    private var sessions: [String: ActiveProcessTapSession] = [:]
    private var failedUntil: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?

    init(outputDeviceUID: String? = nil) {
        self.outputDeviceUID = outputDeviceUID
        refreshProcesses()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshProcesses()
            }
        }
    }

    deinit { refreshTask?.cancel() }

    func volume(for processID: String) -> Float { volumes[processID] ?? 1.0 }
    func isMuted(for processID: String) -> Bool { muteStates[processID] ?? false }

    func setVolume(for process: AudioAppProcess, volume: Float, currentOutputUID: String?) {
        let value = max(0.0, min(1.5, volume))
        volumes[process.id] = value
        setOutputDeviceUID(currentOutputUID)
        if abs(value - 1.0) < 0.001 && !isMuted(for: process.id) {
            sessions[process.id] = nil
            failedUntil[process.id] = nil
            lastErrorMessage = nil
            showCaptureSettingsAction = false
            return
        } else if let activeProcess = processes.first(where: { $0.id == process.id && $0.isPlayingAudio }) {
            ensureSession(for: activeProcess)
            guard let session = sessions[process.id] else { return }
            session.setGain(value)
        } else {
            sessions[process.id]?.setGain(value)
        }
        lastErrorMessage = nil
        showCaptureSettingsAction = false
    }

    func toggleMute(for process: AudioAppProcess, currentOutputUID: String?) {
        let value = !(muteStates[process.id] ?? false)
        muteStates[process.id] = value
        setOutputDeviceUID(currentOutputUID)
        if !value && abs(volume(for: process.id) - 1.0) < 0.001 {
            sessions[process.id] = nil
            failedUntil[process.id] = nil
            lastErrorMessage = nil
            showCaptureSettingsAction = false
            return
        } else if let activeProcess = processes.first(where: { $0.id == process.id && $0.isPlayingAudio }) {
            ensureSession(for: activeProcess)
            guard let session = sessions[process.id] else { return }
            session.setMuted(value)
        } else {
            sessions[process.id]?.setMuted(value)
        }
        lastErrorMessage = nil
        showCaptureSettingsAction = false
    }

    func setOutputDeviceUID(_ uid: String?) {
        guard outputDeviceUID != uid else { return }
        outputDeviceUID = uid
        sessions.removeAll()
        failedUntil.removeAll()
        lastErrorMessage = nil
        showCaptureSettingsAction = false
        synchronizeSessions()
    }

    func refreshProcesses() {
        processes = fetchProcesses()
        synchronizeSessions()
        updateCaptureStatus()
    }

    func clearError() {
        lastErrorMessage = nil
        showCaptureSettingsAction = false
    }

    func openSystemAudioCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func resetAllTaps() {
        sessions.removeAll()
        failedUntil.removeAll()
        volumes.removeAll()
        muteStates.removeAll()
        lastErrorMessage = nil
        showCaptureSettingsAction = false
    }

    private func synchronizeSessions() {
        let activeByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
        for (id, session) in sessions {
            guard let process = activeByID[id], process.isPlayingAudio,
                  process.processObjectIDs == session.processIDs,
                  session.outputUID == outputDeviceUID else {
                sessions[id] = nil
                continue
            }
        }

        guard outputDeviceUID != nil else { return }
        for process in processes where process.isPlayingAudio && requiresTap(for: process.id) {
            ensureSession(for: process)
        }
    }

    private func requiresTap(for processID: String) -> Bool {
        isMuted(for: processID) || abs(volume(for: processID) - 1.0) >= 0.001
    }

    private func ensureSession(for process: AudioAppProcess) {
        guard sessions[process.id] == nil else { return }
        guard let outputDeviceUID else {
            lastErrorMessage = "Uygulama sesini yönlendirmek için etkin bir çıkış aygıtı seçin."
            return
        }
        if let retryAfter = failedUntil[process.id], retryAfter > Date() { return }
        if let session = ActiveProcessTapSession(
            processIDs: process.processObjectIDs,
            outputUID: outputDeviceUID,
            gain: volume(for: process.id),
            muted: isMuted(for: process.id)
        ) {
            sessions[process.id] = session
            failedUntil[process.id] = nil
        } else {
            failedUntil[process.id] = Date().addingTimeInterval(5)
            lastErrorMessage = "\(process.name) için CoreAudio ses oturumu açılamadı. Ses yakalama iznini ve çıkış aygıtı biçimini kontrol edin."
            showCaptureSettingsAction = true
        }
    }

    private func updateCaptureStatus() {
        let activeSessions = processes.compactMap { process -> (String, ActiveProcessTapSession)? in
            guard process.isPlayingAudio, let session = sessions[process.id] else { return nil }
            return (process.name, session)
        }
        if let name = activeSessions.first(where: {
            $0.1.callbackCount >= 120 && $0.1.nonSilentCallbackCount == 0
        })?.0 {
            lastErrorMessage = "\(name) için ses tap'ı sessiz örnekler alıyor. Uygulama ses çıkarıyorsa macOS Sistem Ses Kaydı iznini kontrol edin."
            showCaptureSettingsAction = true
        } else if activeSessions.contains(where: { $0.1.nonSilentCallbackCount > 0 }), showCaptureSettingsAction {
            lastErrorMessage = nil
            showCaptureSettingsAction = false
        } else if activeSessions.isEmpty, showCaptureSettingsAction {
            lastErrorMessage = nil
            showCaptureSettingsAction = false
        }
    }

    private struct ProcessRecord {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isRunningOutput: Bool
    }

    private struct HostApp {
        let id: String
        let pid: pid_t
        let name: String
        let icon: NSImage
    }

    private func fetchProcesses() -> [AudioAppProcess] {
        let records = readProcessObjectIDs().compactMap(readProcessRecord)
        let runningApps = NSWorkspace.shared.runningApplications
        var groups: [String: (host: HostApp, records: [ProcessRecord])] = [:]

        for record in records {
            guard record.pid != ProcessInfo.processInfo.processIdentifier,
                  let host = resolveHostApp(for: record, runningApps: runningApps) else { continue }
            if groups[host.id] == nil {
                groups[host.id] = (host, [record])
            } else {
                groups[host.id]?.records.append(record)
            }
        }

        return groups.compactMap { id, group in
            let processIDs = Array(Set(group.records.map(\.objectID))).sorted()
            guard !processIDs.isEmpty else { return nil }
            return AudioAppProcess(
                id: id,
                processObjectIDs: processIDs,
                pid: group.host.pid,
                name: group.host.name,
                icon: group.host.icon,
                isPlayingAudio: group.records.contains(where: \.isRunningOutput)
            )
        }
        .sorted {
            if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolve helper and renderer processes to the regular .app that owns them. The executable
    /// path is checked first, then the parent chain; a process's bundle ID alone is not enough to
    /// identify its host application (many browser helpers use shared Apple bundle IDs).
    private func resolveHostApp(for record: ProcessRecord, runningApps: [NSRunningApplication]) -> HostApp? {
        if let path = executablePath(for: record.pid),
           let appRange = path.range(of: ".app/") {
            let appPath = String(path[..<appRange.upperBound].dropLast())
            if let app = runningApps.first(where: {
                $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path == appPath
            }) {
                return hostApp(app, fallbackPath: appPath)
            }
        }

        var cursorPID = record.pid
        for _ in 0..<7 {
            if let app = NSRunningApplication(processIdentifier: cursorPID),
               !app.isTerminated,
               app.activationPolicy == .regular {
                return hostApp(app, fallbackPath: app.bundleURL?.path ?? "pid:\(cursorPID)")
            }
            guard let parent = parentPID(of: cursorPID), parent > 1, parent != cursorPID else { break }
            cursorPID = parent
        }

        if let app = NSRunningApplication(processIdentifier: record.pid),
           !app.isTerminated,
           app.activationPolicy == .regular || record.isRunningOutput {
            return hostApp(app, fallbackPath: "pid:\(record.pid)")
        }

        guard record.isRunningOutput else { return nil }
        let bundleID = record.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let icon = NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32))
        return HostApp(id: bundleID, pid: record.pid, name: bundleID, icon: icon)
    }

    private func hostApp(_ app: NSRunningApplication, fallbackPath: String) -> HostApp {
        let id = app.bundleIdentifier ?? fallbackPath
        let name = app.localizedName
            ?? (app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String })
            ?? (app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String })
            ?? URL(fileURLWithPath: fallbackPath).deletingPathExtension().lastPathComponent
        let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32))
        return HostApp(id: id, pid: app.processIdentifier, name: name, icon: icon)
    }

    private func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let result = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard result > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func readProcessObjectIDs() -> [AudioObjectID] {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0,
              byteCount % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        let status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(systemID, &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        return status == noErr ? objectIDs : []
    }

    private func readProcessRecord(_ objectID: AudioObjectID) -> ProcessRecord? {
        guard let pid = readPID(objectID: objectID) else { return nil }
        return ProcessRecord(
            objectID: objectID,
            pid: pid,
            bundleID: readString(objectID: objectID, selector: kAudioProcessPropertyBundleID),
            isRunningOutput: readUInt32(objectID: objectID, selector: kAudioProcessPropertyIsRunningOutput) == 1
        )
    }

    private func readPID(objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var byteCount = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &pid) == noErr else { return nil }
        return pid > 0 ? pid : nil
    }

    private func readUInt32(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value) == noErr else { return nil }
        return value
    }

    private func readString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var byteCount = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, $0)
        }
        guard status == noErr else { return nil }
        let stringValue = value as String
        return stringValue.isEmpty ? nil : stringValue
    }
}
