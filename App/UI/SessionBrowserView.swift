import Foundation
import MimizukuCore
import Observation
import SwiftUI

struct SessionBrowserItem: Identifiable, Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case available(metadata: SessionMetadata, transcript: TranscriptDocument?)
        case recoveryNeeded(reason: String)
    }

    let directory: URL
    let content: Content

    var id: String { directory.standardizedFileURL.path }

    init(state: SessionLoadState) {
        switch state {
        case let .available(directory, metadata, transcript):
            self.directory = directory
            content = .available(metadata: metadata, transcript: transcript)
        case let .recoveryNeeded(directory, reason):
            self.directory = directory
            content = .recoveryNeeded(reason: reason)
        }
    }
}

@MainActor
@Observable
final class SessionBrowserModel {
    private let store: SessionStore

    private(set) var items: [SessionBrowserItem] = []
    private(set) var isLoading = false
    var selectionID: String?

    var selectedItem: SessionBrowserItem? {
        items.first { $0.id == selectionID }
    }

    init(store: SessionStore) {
        self.store = store
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        let states = await Task.detached(priority: .userInitiated) { [store] in
            store.listSessions()
        }.value
        items = states.map(SessionBrowserItem.init)
        if !items.contains(where: { $0.id == selectionID }) {
            selectionID = items.first?.id
        }
        isLoading = false
    }
}

struct SessionBrowserView: View {
    @Bindable var model: SessionBrowserModel

    var body: some View {
        List(model.items, selection: $model.selectionID) { item in
            SessionRow(item: item)
                .tag(item.id)
        }
        .navigationTitle("セッション")
        .overlay {
            if model.isLoading, model.items.isEmpty {
                ProgressView("セッションを読み込み中…")
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "セッションはありません",
                    systemImage: "waveform",
                    description: Text("録音を完了すると、ここから確認できます。")
                )
            }
        }
    }
}

private struct SessionRow: View {
    let item: SessionBrowserItem

    var body: some View {
        switch item.content {
        case let .available(metadata, _):
            availableRow(metadata)
        case .recoveryNeeded:
            recoveryRow
        }
    }

    private func availableRow(_ metadata: SessionMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SessionFormatting.title(for: metadata))
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(metadata.startedAt, format: .dateTime.year().month().day().hour().minute())
                Text("·")
                Text(SessionFormatting.duration(metadata.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            statusLabel(metadata.status)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionFormatting.accessibilityLabel(for: metadata))
    }

    private var recoveryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("復旧が必要", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(item.directory.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("復旧が必要なセッション、\(item.directory.lastPathComponent)")
    }

    @ViewBuilder
    private func statusLabel(_ status: SessionStatus) -> some View {
        switch status {
        case .recording:
            Label("録音中", systemImage: "record.circle")
                .foregroundStyle(.red)
        case .completed:
            Label("完了", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .interrupted:
            Label("中断", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .recoveryNeeded:
            Label("復旧が必要", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

enum SessionFormatting {
    static func title(for metadata: SessionMetadata) -> String {
        let trimmed = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return metadata.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func timestamp(_ interval: TimeInterval?) -> String {
        guard let interval else { return "時刻なし" }
        return duration(interval)
    }

    static func recoveryMessage(_ reason: String) -> String {
        switch reason {
        case "未確定の文字起こしジャーナルがあります。",
             "録音中の状態で終了したセッションです。":
            reason
        default:
            "セッションデータを読み込めませんでした。"
        }
    }

    static func accessibilityLabel(for metadata: SessionMetadata) -> String {
        let status = switch metadata.status {
        case .recording: "録音中"
        case .completed: "完了"
        case .interrupted: "中断"
        case .recoveryNeeded: "復旧が必要"
        }
        let startedAt = metadata.startedAt.formatted(date: .long, time: .shortened)
        return "\(title(for: metadata))、\(startedAt)、\(duration(metadata.duration))、\(status)"
    }
}
