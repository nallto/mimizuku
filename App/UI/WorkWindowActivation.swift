import AppKit
import SwiftUI

/// `LSUIElement=true`を維持しながら、作業ウィンドウがある間だけ標準メニューとDockへ参加する。
@MainActor
enum WorkWindowActivation {
    private static var presentedWindowIDs: Set<String> = []

    static func open(id: String, using openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate()
    }

    static func didAppear(id: String) {
        presentedWindowIDs.insert(id)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func didDisappear(id: String) {
        presentedWindowIDs.remove(id)
        Task { @MainActor in
            // SwiftUIが閉じるウィンドウの状態をAppKitへ反映するまで1ターン待つ。
            await Task.yield()
            guard presentedWindowIDs.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct WorkWindowLifecycleModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .onAppear { WorkWindowActivation.didAppear(id: id) }
            .onDisappear { WorkWindowActivation.didDisappear(id: id) }
    }
}

extension View {
    func workWindowLifecycle(id: String) -> some View {
        modifier(WorkWindowLifecycleModifier(id: id))
    }
}
