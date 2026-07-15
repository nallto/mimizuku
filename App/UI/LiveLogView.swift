import MimizukuCore
import SwiftUI

/// ライブ議事ログのウィンドウ。確定行を上へ追記し、現在の volatile 行を最下部に
/// 薄く(dimmed)描画する。上部にモデルアセットの状態バナーを出す。
struct LiveLogView: View {
    let controller: AudioSessionController

    private let bottomAnchor = "log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AssetStatusBanner(status: controller.assetStatus)
            Divider()
            transcript
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.log.finalized) { segment in
                        Text(segment.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 現在の volatile 行(未確定)を薄く表示する。
                    ForEach(controller.log.volatileLines) { segment in
                        Text(segment.text)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
