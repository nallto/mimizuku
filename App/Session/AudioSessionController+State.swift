// MARK: - UI公開状態

extension AudioSessionController {
    func toggle() {
        if isRunning { stop() } else { start() }
    }

    var menuState: MenuState {
        if lastError != nil { return .error }
        if case .failed = assetStatus { return .error }
        return isRunning ? .recording : .idle
    }

    /// メニューバーアイコンが表す動作状況(#35: 待機 / 録音中 / エラーの3状態)。
    enum MenuState {
        case idle
        case recording
        case error
    }

    /// エコーキャンセル(AEC)の適用状態(権限診断画面の表示用、#64)。
    enum AecStatus: Equatable {
        /// 未実行、またはこのモードではAECを使わない(システム音声のみ)。
        case notApplicable
        /// APMは初期化済みで、参照音声の初回フレームを待っている。
        case starting
        /// 有効な参照音声を取得し、AECを適用中。
        case active
        /// 参照音声の一時停止から復旧中。マイク原音は無音へ置き換える。
        case recovering
        /// AECを開始・復旧できず、セッションを継続できない。
        case failed(reason: String)
        /// 診断用に参照tapを止めている(ADR-0016 決定13)。セッションは継続し、
        /// **AEC未処理のマイク原音を保存・文字起こしする**。通常運用では発生しない。
        case diagnosticBypass
    }
}
