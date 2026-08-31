import CoreAudio
import Foundation

/// Enumerates Core Audio input devices so the mic track can be pinned to a
/// specific one instead of following the system default. Following the default
/// means plugging in headphones silently switches which microphone records the
/// meeting — usually to the worse one.
enum AudioDevices {
    struct Device: Sendable, Equatable {
        let id: AudioDeviceID
        /// Human-readable name, e.g. "MacBook Pro Microphone".
        let name: String
        /// Stable across reboots and re-plugs; what we persist in config.
        let uid: String
        let inputChannels: Int
    }

    /// Every device with at least one input channel, in Core Audio's order.
    static func inputs() -> [Device] {
        allDeviceIDs()
            .map(describe)
            .compactMap { $0 }
            .filter { $0.inputChannels > 0 }
    }

    /// The device Core Audio would pick on its own.
    static func defaultInput() -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr else { return nil }
        return describe(id)
    }

    /// Resolve a config value to a live device. Matches UID first (exact,
    /// survives renames), then a case-insensitive name substring — so
    /// `"mic_device": "MacBook"` keeps working across machines. Returns nil
    /// when the named device isn't currently connected; callers fall back to
    /// the system default rather than failing the recording.
    static func resolve(_ wanted: String) -> Device? {
        let devices = inputs()
        if let exact = devices.first(where: { $0.uid == wanted }) { return exact }
        let needle = wanted.lowercased()
        return devices.first { $0.name.lowercased().contains(needle) }
    }

    // MARK: -

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func describe(_ id: AudioDeviceID) -> Device? {
        guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? name
        return Device(id: id, name: name, uid: uid, inputChannels: inputChannels(id))
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Total input channels across every stream in the input scope. Zero means
    /// it's an output-only device (speakers) and can't record us.
    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
