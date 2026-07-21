import AppKit
import MimizukuCore
import SwiftUI

/// ライブ議事ログのウィンドウ。確定行を上へ追記し、現在の volatile 行を最下部に
/// 薄く(dimmed)描画する。上部にモデルアセットの状態バナーを出す。
struct LiveLogView: View {
    let controller: AudioSessionController

    private let bottomAnchor = "log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AssetStatusBanner(status: controller.assetStatus)
                copyAllButton
            }
            Divider()
            transcript
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    /// テスト用の一時 UI: 確定行の全文をクリップボードへコピーする(台本との照合用)。
    /// メイン画面統合(S9)で選択ポップアップ等の恒久 UI に置き換えて退役する。
    private var copyAllButton: some View {
        Button {
            let text = controller.log.finalized.map(\.text).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label("全文コピー", systemImage: "doc.on.doc")
        }
        .disabled(controller.log.finalized.isEmpty)
        .controlSize(.small)
        .padding(.trailing, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.log.finalized) { segment in
                        row(for: segment, dimmed: false)
                    }
                    // 現在の volatile 行(未確定)を薄く表示する。ストリーム毎に 1 行なので
                    // id はストリームで固定し、更新のたびの remove+insert を避ける。
                    ForEach(controller.log.volatileLines, id: \.stream) { segment in
                        row(for: segment, dimmed: true)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding()
            }
            .onChange(of: controller.log.finalized.count) {
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    /// 1 セグメント = ストリームラベル + 本文。ラベルは会話の役割で表す
    /// (マイク = 自分、システム音声 = 相手。相手側の話者分離はしない ――
    /// domain-pitfalls #7 の範囲)。
    private func row(for segment: TranscriptSegment, dimmed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.streamLabel(segment.stream))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(segment.text)
                .textSelection(.enabled)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func streamLabel(_ stream: StreamKind) -> String {
        switch stream {
        case .microphone: "自分"
        case .systemAudio: "相手"
        }
    }
}

/// モデルアセットの導入状態バナー。ダウンロード中は不確定スピナーを回して「動いている」
/// ことを示す(進捗率は出さない)。
private struct AssetStatusBanner: View {
    let status: ModelAssetStatus

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .notInstalled:
                Image(systemName: "arrow.down.circle")
                Text("音声モデル未導入")
            case .downloading:
                ProgressView().controlSize(.small)
                Text("音声モデルを準備中…")
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("準備完了")
            case let .failed(reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("準備に失敗: \(reason)").lineLimit(2)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
