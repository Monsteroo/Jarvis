import Foundation
import CoreAudio

@MainActor protocol OutputTarget: AnyObject {
    func isCurrent() -> Bool
    func readVolumes() throws -> [Float]
    func writeVolumes(_ values: [Float]) throws
    func readMute() throws -> Bool
    func writeMute(_ value: Bool) throws
}
@MainActor protocol OutputAccess { func target() throws -> OutputTarget }

@MainActor struct AudioOutputActions {
    let access: OutputAccess
    func perform(_ action: Action, language: String) -> CommandOutcome {
        let fail = actionText(language, "Пристрій виводу не підтримує цю дію або змінився. Перевірте налаштування звуку.", "The output device changed or does not support this action. Check Sound settings.")
        var wrote = false
        do {
            try Task.checkCancellation()
            let target = try access.target()
            guard target.isCurrent() else { return .failed(reason: fail) }
            let confirmed: Bool
            switch action {
            case .mute(let value):
                _ = try target.readMute()
                try Task.checkCancellation()
                try Task.checkCancellation()
                wrote = true; try target.writeMute(value)
                confirmed = try target.readMute() == value
            case .volumeSet(let percent):
                guard (0...100).contains(percent) else { return .failed(reason: fail) }
                let old = try target.readVolumes()
                guard !old.isEmpty else { return .failed(reason: fail) }
                let values = old.map { _ in Float(percent)/100 }
                try Task.checkCancellation()
                wrote = true; try target.writeVolumes(values)
                confirmed = try matches(target.readVolumes(), values)
            case .volumeStep(let step):
                guard (-100...100).contains(step), step != 0 else { return .failed(reason: fail) }
                let old = try target.readVolumes()
                guard !old.isEmpty, old.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .failed(reason: fail) }
                let values = old.map { max(0, min(1, $0 + Float(step)/100)) }
                try Task.checkCancellation()
                wrote = true; try target.writeVolumes(values)
                confirmed = try matches(target.readVolumes(), values)
            default: return .failed(reason: fail)
            }
            guard target.isCurrent(), confirmed else { return .partial(summary: actionText(language, "Зміну звуку не підтверджено.", "The sound change was not confirmed."), details: fail) }
            return .done(summary: actionText(language, "Налаштування звуку змінено.", "Sound settings changed."))
        } catch { }
        return wrote ? .partial(summary: actionText(language, "Звук міг змінитися частково.", "Sound may have changed partially."), details: fail) : .failed(reason: fail)
    }
    private func matches(_ actual: [Float], _ expected: [Float]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { $0.isFinite && abs($0 - $1) <= 0.015 }
    }
}

@MainActor struct MacOutputAccess: OutputAccess {
    static func defaultDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { throw DeviceActionError.unavailable }
        return device
    }
    func target() throws -> OutputTarget { MacOutputTarget(try Self.defaultDevice()) }
}

@MainActor private final class MacOutputTarget: OutputTarget {
    let device: AudioDeviceID
    init(_ device: AudioDeviceID) { self.device = device }
    func isCurrent() -> Bool { (try? MacOutputAccess.defaultDevice()) == device }
    private func address(_ selector: AudioObjectPropertySelector, _ channel: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
    }
    private func writable(_ selector: AudioObjectPropertySelector, _ channel: UInt32 = 0) -> Bool {
        var a = address(selector, channel), yes = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &yes) == noErr && yes.boolValue
    }
    /// Preflight every channel before touching any. Master control is preferred.
    private func volumeChannels() throws -> [UInt32] {
        if writable(kAudioDevicePropertyVolumeScalar) { return [0] }
        var a = address(kAudioDevicePropertyStreamConfiguration), bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size, bytes <= 65536 else { throw DeviceActionError.unsupported }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &bytes, raw) == noErr else { throw DeviceActionError.unsupported }
        let pointer = raw.assumingMemoryBound(to: AudioBufferList.self)
        let capacity = (Int(bytes) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride + 1
        guard pointer.pointee.mNumberBuffers <= capacity else { throw DeviceActionError.unsupported }
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        let count = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0, count <= 64 else { throw DeviceActionError.unsupported }
        let channels = (1...UInt32(count)).map { $0 }
        guard channels.allSatisfy({ writable(kAudioDevicePropertyVolumeScalar, $0) }) else { throw DeviceActionError.unsupported }
        return channels
    }
    private func volume(_ channel: UInt32) throws -> Float {
        var a = address(kAudioDevicePropertyVolumeScalar, channel), value: Float32 = 0, bytes = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &bytes, &value) == noErr, value.isFinite, (0...1).contains(value) else { throw DeviceActionError.unavailable }
        return value
    }
    func readVolumes() throws -> [Float] { try volumeChannels().map { try volume($0) } }
    func writeVolumes(_ values: [Float]) throws {
        let channels = try volumeChannels()
        guard values.count == channels.count, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw DeviceActionError.unsupported }
        for (channel, value) in zip(channels, values) {
            try Task.checkCancellation()
            guard isCurrent() else { throw DeviceActionError.unavailable }
            var a = address(kAudioDevicePropertyVolumeScalar, channel), scalar = value
            guard AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr else { throw DeviceActionError.writeFailed }
        }
    }
    func readMute() throws -> Bool {
        var a = address(kAudioDevicePropertyMute), value: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &bytes, &value) == noErr else { throw DeviceActionError.unsupported }
        return value != 0
    }
    func writeMute(_ value: Bool) throws {
        try Task.checkCancellation()
        guard isCurrent(), writable(kAudioDevicePropertyMute) else { throw DeviceActionError.unsupported }
        var a = address(kAudioDevicePropertyMute), number: UInt32 = value ? 1 : 0
        guard AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &number) == noErr else { throw DeviceActionError.writeFailed }
    }
}
