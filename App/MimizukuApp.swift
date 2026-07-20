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
        MenuBarExtra("Mimizuku", systemImage: "waveform") {
            MenuContent(controller: controller, logWindowID: Self.logWindowID)
        }

        // アセットのバックグラウンド導入は controller の init で起動時に開始する。
        Window("ライブ議事ログ", id: Self.logWindowID) {
            LiveLogView(controller: controller)
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
        switch controller.assetStatus {
        case .notInstalled: "音声モデル未導入"
        case .downloading: "音声モデルを準備中…"
        case .ready: controller.isRunning ? "文字起こし中" : "準備完了"
        case .failed: "モデル準備に失敗"
        }
    }
}
