import MimizukuCore
import SwiftUI

struct TranscriptWorkspaceView: View {
    let item: SessionBrowserItem?

    var body: some View {
        switch item?.content {
        case nil:
            ContentUnavailableView(
                "セッションを選択",
                systemImage: "text.bubble",
                description: Text("左の一覧から、確認するセッションを選んでください。")
            )
        case let .recoveryNeeded(reason):
            ContentUnavailableView(
                "復旧が必要です",
                systemImage: "exclamationmark.triangle",
                description: Text(
                    "\(SessionFormatting.recoveryMessage(reason)) 保存済みデータは削除されていません。"
                )
            )
        case let .available(metadata, transcript):
            AvailableTranscriptView(metadata: metadata, transcript: transcript)
        }
    }
}

private struct AvailableTranscriptView: View {
    let metadata: SessionMetadata
    let transcript: TranscriptDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionHeader
            Divider()
            transcriptContent
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SessionFormatting.title(for: metadata))
                .font(.title2)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                statusLabel
                Text(metadata.startedAt, format: .dateTime.year().month().day().hour().minute())
                Text(SessionFormatting.duration(metadata.duration))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch metadata.status {
        case .recording:
            Label("録音中", systemImage: "record.circle")
        case .completed:
            Label("完了", systemImage: "checkmark.circle")
        case .interrupted:
            Label("中断", systemImage: "exclamationmark.triangle")
        case .recoveryNeeded:
            Label("復旧が必要", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if let transcript, !transcript.blocks.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(transcript.blocks) { block in
                        TranscriptBlockView(block: block, metadata: metadata)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            ContentUnavailableView(
                "文字起こしはありません",
                systemImage: "text.bubble",
                description: Text("このセッションには保存済みの文字起こしがありません。")
            )
        }
    }
}

private struct TranscriptBlockView: View {
    private struct Speaker {
        let label: String
    }

    let block: TranscriptBlock
    let metadata: SessionMetadata

    private var speaker: Speaker {
        guard let track = metadata.tracks.first(where: { $0.id == block.trackID }) else {
            return Speaker(label: "不明")
        }
        switch track.origin {
        case .microphone:
            return Speaker(label: "自分")
        case .systemAudio:
            return Speaker(label: "相手")
        case .importedAudio:
            return Speaker(label: track.label)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SessionFormatting.timestamp(block.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(speaker.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(block.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !block.isComplete {
                Label("不完全な末尾", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let completeness = block.isComplete ? "" : "、不完全な末尾"
        let timestamp = SessionFormatting.timestamp(block.start)
        return "\(timestamp)、\(speaker.label)\(completeness)、\(block.text)"
    }
}
