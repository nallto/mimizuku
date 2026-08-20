import AVFoundation
import CoreAudio
import Foundation

// MARK: - CoreAudio ヘルパー(controlQueue)

/// tap・aggregate device・既定出力デバイスに触る同期 CoreAudio 呼び出し。呼び出し側は
/// `TapSession` の controlQueue のみ(HAL への同期照会を main thread で行わない ――
/// docs/domain-pitfalls.md #10)。
extension TapSession {
    static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemAudioTapError.coreAudio(operation: operation, status: status)
        }
    }

    func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            "ReadTapFormat"
        )
        return asbd
    }

    func defaultOutputDeviceUID() throws -> String {
        var address = Self.defaultOutputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            ),
            "ReadDefaultOutputDevice"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw SystemAudioTapError.defaultOutputDeviceUnavailable
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CFString プロパティは Unmanaged で受ける(CFString 変数への直接ポインタ形成は
        // オブジェクト参照を壊しうる)。Get 系プロパティは retained で返るため takeRetained。
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &uidRef) { pointer in
            try check(
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer),
                "ReadDeviceUID"
            )
        }
        guard let uid = uidRef?.takeRetainedValue() else {
            throw SystemAudioTapError.defaultOutputDeviceUnavailable
        }
        return uid as String
    }
}
