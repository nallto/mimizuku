import AppKit
import SwiftUI

/// メニューバー常駐アプリのエントリポイント。
///
/// メニューバーから開始/停止を操作し、ライブ議事ログは専用ウィンドウで表示する。
/// 捕捉/文字起こしのロジックは `MimizukuCore` の契約越しに App 層の具象
/// (`MicrophoneSource` / `SpeechEngine`)へ配線する(ADR-0003)。
@main
struct MimizukuApp: App {
    /// アプリ全体で 1 つのセッション状態を共有する。
    @State private var controller = AudioSessionController()

    private static let logWindowID = "live-log"

    var body: some Scene {
        // アイコンの形状で動作状況を伝える(#35。色だけに依存しない ―― macos-ui-design)。
        MenuBarExtra("Mimizuku", systemImage: menuSymbol) {
            MenuContent(controller: controller, logWindowID: Self.logWindowID)
        }

        // アセットのバックグラウンド導入は controller の init で起動時に開始する。
        Window("ライブ議事ログ", id: Self.logWindowID) {
            LiveLogView(controller: controller)
        }
    }

    private var menuSymbol: String {
        switch controller.menuState {
        case .idle: "waveform"
        case .recording: "record.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

/// メニューバーのドロップダウン内容。開始/停止・状態・ウィンドウ表示・終了。
private struct MenuContent: View {
    let controller: AudioSessionController
    let logWindowID: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(controller.isRunning ? "停止" : "開始") {
            controller.toggle()
        }
        .keyboardShortcut("r")

        Text(statusText)

        Divider()

        Button("議事ログを開く") {
            openWindow(id: logWindowID)
        }
        .keyboardShortcut("l")

        Divider()

        Button("Mimizuku を終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        if let lastError = controller.lastError {
            return "エラー: \(lastError)"
        }
        switch controller.assetStatus {
        case .notInstalled: return "音声モデル未導入"
        case .downloading: return "音声モデルを準備中…"
        case .ready: return controller.isRunning ? "録音・文字起こし中" : "準備完了"
        case .failed: return "モデル準備に失敗"
        }
    }
}
