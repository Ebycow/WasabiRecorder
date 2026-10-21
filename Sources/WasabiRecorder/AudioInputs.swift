import CoreAudio
import Foundation

/// A microphone / audio-interface input and which of its channels to record.
struct InputSelection: Equatable, Codable {
    let deviceUID: String
    let deviceName: String
    /// Zero-based device channels: one for mono, two for stereo.
    let channels: [Int]

    var isMono: Bool { channels.count == 1 }

    var channelLabel: String {
        channels.map { "\($0 + 1)" }.joined(separator: "-")
    }
}

struct InputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channelCount: Int

    func matches(_ selection: InputSelection) -> Bool { uid == selection.deviceUID }
}

enum AudioInputs {
    static func current() -> [InputDevice] {
        let devices = (try? AudioObjectID.system.getObjectList(kAudioHardwarePropertyDevices)) ?? []
        return devices.compactMap { device in
            let channels = inputChannelCount(of: device)
            guard channels > 0,
                  let uid = try? device.getString(kAudioDevicePropertyDeviceUID),
                  let name = try? device.getString(kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: device, uid: uid, name: name, channelCount: channels)
        }
    }

    static func device(uid: String) -> AudioObjectID? {
        current().first { $0.uid == uid }?.id
    }

    static func inputChannelCount(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
