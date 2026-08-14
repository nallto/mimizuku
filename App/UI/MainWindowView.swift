import MimizukuCore
import SwiftUI

enum MainWindowMetrics {
    static let defaultWidth: CGFloat = 1200
    static let defaultHeight: CGFloat = 680
    static let sidebarMinimum: CGFloat = 160
    static let sidebarIdeal: CGFloat = 240
    static let sidebarMaximum: CGFloat = 320
    static let workspaceMinimum: CGFloat = 480
    static let inspectorMinimum: CGFloat = 240
    static let inspectorIdeal: CGFloat = 360
    static let inspectorMaximum: CGFloat = 600
}

/// 保存済みセッションを選び、文字起こしを確認するメインウィンドウ(S6)。
struct MainWindowView: View {
    @State private var model: SessionBrowserModel
    @AppStorage("mainWindow.sidebarPresented") private var isSidebarPresented = true
    @AppStorage("mainWindow.inspectorPresented") private var isInspectorPresented = true
    @Environment(\.scenePhase) private var scenePhase

    init(store: SessionStore) {
        _model = State(initialValue: SessionBrowserModel(store: store))
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            isSidebarPresented ? .all : .detailOnly
        } set: { visibility in
            isSidebarPresented = visibility != .detailOnly
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SessionBrowserView(model: model)
                .navigationSplitViewColumnWidth(
                    min: MainWindowMetrics.sidebarMinimum,
                    ideal: MainWindowMetrics.sidebarIdeal,
                    max: MainWindowMetrics.sidebarMaximum
                )
        } detail: {
            TranscriptWorkspaceView(item: model.selectedItem)
                .frame(
                    minWidth: MainWindowMetrics.workspaceMinimum,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .inspector(isPresented: $isInspectorPresented) {
            InspectorPlaceholderView()
                .inspectorColumnWidth(
                    min: MainWindowMetrics.inspectorMinimum,
                    ideal: MainWindowMetrics.inspectorIdeal,
                    max: MainWindowMetrics.inspectorMaximum
                )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("インスペクタ", systemImage: "sidebar.trailing")
                }
                .help(isInspectorPresented ? "インスペクタを隠す" : "インスペクタを表示")
            }
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task { await model.reload() }
        }
    }
}

private struct InspectorPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("インスペクタ", systemImage: "sidebar.trailing")
                .font(.headline)
            Text("要約、TODO、メモはまだ利用できません。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}
