import Foundation
import Testing

@testable import MimizukuCore

struct AecDiagnosticsLayoutTests {
    private func makeTempLayout() throws -> AecDiagnosticsLayout {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "AecDiagnosticsLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AecDiagnosticsLayout(root: root)
    }

    @Test func defaultLayoutUsesXdgStateHomeWhenAbsolute() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let layout = AecDiagnosticsLayout.defaultLayout(
            environment: ["XDG_STATE_HOME": "/custom/state"],
            homeDirectory: home
        )
        #expect(layout.root.path == "/custom/state/mimizuku/aec-diagnostics")
    }

    @Test func defaultLayoutFallsBackToLocalState() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        // 未設定・空・相対パスはすべて既定(~/.local/state)へフォールバック(ADR-0006 と同規則)。
        for env in [[:], ["XDG_STATE_HOME": ""], ["XDG_STATE_HOME": "relative/path"]] {
            let layout = AecDiagnosticsLayout.defaultLayout(environment: env, homeDirectory: home)
            #expect(layout.root.path == "/Users/test/.local/state/mimizuku/aec-diagnostics")
        }
    }

    @Test func sessionDataRootIsDisjointFromDiagnosticsRoot() {
        // ADR-0015 の分離不変条件: 既定同士でセッションデータと診断データの親が交わらない。
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let sessions = SessionLayout.defaultLayout(environment: [:], homeDirectory: home)
        let diagnostics = AecDiagnosticsLayout.defaultLayout(environment: [:], homeDirectory: home)
        #expect(!diagnostics.root.path.hasPrefix(sessions.root.path))
        #expect(!sessions.root.path.hasPrefix(diagnostics.root.path))
    }

    @Test func createTrialDirectoryAvoidsCollisionWithSuffix() throws {
        let layout = try makeTempLayout()
        let date = Date(timeIntervalSince1970: 1_785_484_800)
        let first = try layout.createTrialDirectory(startedAt: date)
        let second = try layout.createTrialDirectory(startedAt: date)
        let third = try layout.createTrialDirectory(startedAt: date)
        // 上書き禁止(ADR-0015 の 2): 同一秒の再試行は -2 以降を付けた別ディレクトリになる。
        #expect(first.lastPathComponent != second.lastPathComponent)
        #expect(second.lastPathComponent == "\(first.lastPathComponent)-2")
        #expect(third.lastPathComponent == "\(first.lastPathComponent)-3")
        for url in [first, second, third] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}
