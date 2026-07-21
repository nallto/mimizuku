import AppKit
import Foundation
import Observation

/// 権限診断画面の状態(#37)。マイク / システム音声の権限プローブ結果を保持する。
/// 音声モデルの状態は `AudioSessionController.assetStatus` が持つため、ここには置かない。
@MainActor
@Observable
final class PermissionDiagnostics {
    /// システム音声プローブ(`SystemAudioProbe`)の表示状態。
    enum SystemAudioStatus: Equatable {
        /// 未確認(プローブは tap 生成を伴うため、ユーザー操作で明示的に実行する)。
        case unknown
        case probing
        /// tap 生成に成功。TCC 拒否でも生成が成功して無音になる形はありうるため、
        /// UI は「利用可能」と断定しない文言にする。
        case available
        case failed(reason: String)
    }

    private(set) var microphone: MicrophonePermission.Status = MicrophonePermission.status()
    private(set) var systemAudio: SystemAudioStatus = .unknown

    /// マイク権限の表示を最新化する(ウィンドウ表示時・設定から戻ったとき)。
    func refresh() {
        microphone = MicrophonePermission.status()
    }

    /// マイク権限を要求する(未決定のときだけシステムのプロンプトが出る)。
    func requestMicrophone() async {
        _ = await MicrophonePermission.request()
        refresh()
    }

    /// システム音声 tap の生成プローブを実行する(初回は TCC プロンプトが出る)。
    func probeSystemAudio() async {
        guard systemAudio != .probing else { return }
        systemAudio = .probing
        switch await Self.probeOffMain() {
        case .success:
            systemAudio = .available
        case let .failure(error):
            systemAudio = .failed(reason: error.localizedDescription)
        }
    }

    func openSettings(_ pane: PrivacySettingsPane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// CoreAudio の同期 API を MainActor の外で実行する。
    private nonisolated static func probeOffMain() async -> Result<Void, SystemAudioTapError> {
        SystemAudioProbe.probe()
    }
}
