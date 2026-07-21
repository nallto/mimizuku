import AVFoundation
import CoreAudio
import Foundation

/// マイク(TCC)の状態照会と要求。照会(`status()`)はプロンプトを出さない。
/// 要求(`request()`)は未決定のときだけシステムのプロンプトを出す。
enum MicrophonePermission {
    enum Status: Equatable {
        case undetermined
        case granted
        case denied
    }

    static func status() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// システム音声捕捉(Core Audio process tap)の事前プローブ。
///
/// システム音声の TCC 状態を照会する公開 API は無いため、**process tap の生成試行**を
/// 可用性の代理指標とする(生成のみで aggregate device は作らない)。
/// - 成功 = API 経路は利用可能(初回はここでシステムの TCC プロンプトが出る)。
/// - 失敗 = 未許可または環境不備。どちらかはコードから断定できないため、
///   UI では断定表現を避ける(拒否時に生成は成功して無音だけが返る形もありうる)。
enum SystemAudioProbe {
    /// tap を生成 → 即破棄して成否を返す。CoreAudio の同期 API のため main thread で
    /// 呼ばない(呼び出し側が off-main で実行する)。
    static func probe() -> Result<Void, SystemAudioTapError> {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Mimizuku Permission Probe"
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            return .failure(.coreAudio(operation: "CreateProcessTap", status: status))
        }
        AudioHardwareDestroyProcessTap(tapID)
        return .success(())
    }
}

/// システム設定のプライバシーペインへの deep link。
enum PrivacySettingsPane: String {
    case microphone = "Privacy_Microphone"
    /// システム音声(オーディオ録音)。ペイン ID が OS 更新で無効になった場合は
    /// プライバシールートにフォールバックして開く(リンク自体は失敗しない)。
    case audioCapture = "Privacy_AudioCapture"

    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}
