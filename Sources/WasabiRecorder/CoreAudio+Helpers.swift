import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) に失敗しました (\(status))"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func get<T>(_ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check(status, "プロパティ取得")
        return value
    }

    func get<T>(_ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        (try? get(selector, initial: fallback)) ?? fallback
    }

    func getString(_ selector: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try get(selector, initial: nil)
        guard let value else { throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "文字列取得") }
        return value.takeRetainedValue() as String
    }

    func getObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "リストサイズ取得")
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids), "リスト取得")
        return ids
    }
}
