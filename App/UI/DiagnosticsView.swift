import MimizukuCore
import SwiftUI

/// 権限診断ウィンドウ(#37)。マイク / システム音声 / 音声モデルの 3 項目を、
/// 状態アイコン + 修正アクションつきで表示する。標準の grouped Form を使う
/// (macos-ui-design: 標準コンポーネント優先)。
struct DiagnosticsView: View {
    let controller: AudioSessionController

    @State private var diagnostics = PermissionDiagnostics()

    var body: some View {
        Form {
            Section("マイク(自分の声)") {
                microphoneRow
            }
            Section("システム音声(相手の声)") {
                systemAudioRow
            }
            Section("音声認識モデル") {
                assetRow
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 340)
        .onAppear { diagnostics.refresh() }
    }

    // MARK: - マイク

    @ViewBuilder
    private var microphoneRow: some View {
        switch diagnostics.microphone {
        case .granted:
            statusRow(icon: "checkmark.circle.fill", tint: .green, text: "許可されています。")
        case .undetermined:
            statusRow(
                icon: "questionmark.circle",
                tint: .secondary,
                text: "未確認です。要求すると許可ダイアログが表示されます。"
            ) {
                Button("アクセスを要求") {
                    Task { await diagnostics.requestMicrophone() }
                }
            }
        case .denied:
            statusRow(
                icon: "xmark.circle.fill",
                tint: .orange,
                text: "拒否されています。録音・文字起こしにはシステム設定での許可が必要です。"
            ) {
                Button("システム設定を開く") { diagnostics.openSettings(.microphone) }
                Button("再確認") { diagnostics.refresh() }
            }
        }
    }

    // MARK: - システム音声

    @ViewBuilder
    private var systemAudioRow: some View {
        switch diagnostics.systemAudio {
        case .unknown:
            statusRow(
                icon: "questionmark.circle",
                tint: .secondary,
                text: "未確認です。確認すると捕捉経路を試行します(初回は許可ダイアログが表示されます)。"
            ) {
                Button("確認する") {
                    Task { await diagnostics.probeSystemAudio() }
                }
            }
        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("確認中…")
            }
        case .available:
            // TCC 拒否でも tap 生成が成功して無音だけが返る形はありうるため断定しない。
            statusRow(
                icon: "checkmark.circle.fill",
                tint: .green,
                text: "捕捉経路は利用できます。録音しても無音になる場合は、システム設定の許可を確認してください。"
            ) {
                Button("システム設定を開く") { diagnostics.openSettings(.audioCapture) }
            }
        case let .failed(reason):
            statusRow(
                icon: "xmark.circle.fill",
                tint: .orange,
                text: "捕捉経路を確認できませんでした: \(reason)"
            ) {
                Button("システム設定を開く") { diagnostics.openSettings(.audioCapture) }
                Button("再確認") {
                    Task { await diagnostics.probeSystemAudio() }
                }
            }
        }
    }

    // MARK: - 音声モデル

    @ViewBuilder
    private var assetRow: some View {
        switch controller.assetStatus {
        case .notInstalled:
            statusRow(
                icon: "arrow.down.circle",
                tint: .secondary,
                text: "未導入です(起動時に自動ダウンロードが始まります)。"
            ) {
                Button("ダウンロード") {
                    Task { await controller.prepareAssets() }
                }
            }
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("ダウンロード中…(数百 MB。完了すると自動で利用可能になります)")
            }
        case .ready:
            statusRow(icon: "checkmark.circle.fill", tint: .green, text: "利用できます。")
        case let .failed(reason):
            statusRow(icon: "xmark.circle.fill", tint: .orange, text: "導入に失敗しました: \(reason)") {
                Button("再試行") {
                    Task { await controller.prepareAssets() }
                }
            }
        }
    }

    // MARK: - 共通行

    private func statusRow(
        icon: String,
        tint: Color,
        text: String,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
    }
}
