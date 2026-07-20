import Foundation
import Testing

@testable import MimizukuCore

struct SessionLayoutTests {
    /// 一時ディレクトリを root にした layout(テスト毎に独立)。
    private func makeTempLayout() throws -> SessionLayout {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "SessionLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionLayout(root: root)
    }

    @Test func directoryNameIsLocalTimestamp() {
        let date = Date(timeIntervalSince1970: 1_752_984_000) // 2025-07-20 04:00:00 UTC
        let name = SessionLayout.directoryName(for: date, timeZone: .gmt)
        #expect(name == "20250720-040000")
    }

    @Test func recordingFileNamesFollowAdr0006() {
        #expect(SessionLayout.recordingFileName(for: .microphone) == "mic.caf")
        #expect(SessionLayout.recordingFileName(for: .systemAudio) == "system.caf")
    }

    @Test func defaultLayoutUsesXdgDataHomeWhenAbsolute() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let layout = SessionLayout.defaultLayout(
            environment: ["XDG_DATA_HOME": "/custom/data"],
            homeDirectory: home
        )
        #expect(layout.root.path == "/custom/data/mimizuku/sessions")
    }

    @Test func defaultLayoutFallsBackToLocalShare() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        // 未設定・空・相対パスはすべて既定(~/.local/share)へフォールバック。
        for env in [[:], ["XDG_DATA_HOME": ""], ["XDG_DATA_HOME": "relative/path"]] {
            let layout = SessionLayout.defaultLayout(environment: env, homeDirectory: home)
            #expect(layout.root.path == "/Users/test/.local/share/mimizuku/sessions")
        }
    }

    @Test func createSessionDirectoryAvoidsCollisions() throws {
        let layout = try makeTempLayout()
        let date = Date(timeIntervalSince1970: 1_752_984_000)

        let first = try layout.createSessionDirectory(startedAt: date)
        let second = try layout.createSessionDirectory(startedAt: date)
        let third = try layout.createSessionDirectory(startedAt: date)

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(second.lastPathComponent == first.lastPathComponent + "-2")
        #expect(third.lastPathComponent == first.lastPathComponent + "-3")
    }

    @Test func pendingRecordingsListsOnlyCafFiles() throws {
        let layout = try makeTempLayout()
        let dirA = try layout.createSessionDirectory(startedAt: Date(timeIntervalSince1970: 0))
        let dirB = try layout.createSessionDirectory(startedAt: Date(timeIntervalSince1970: 60))
        let cafA = dirA.appending(component: "mic.caf")
        let m4aA = dirA.appending(component: "system.m4a")
        let cafB = dirB.appending(component: "system.caf")
        for url in [cafA, m4aA, cafB] {
            try Data().write(to: url)
        }
        // root 直下の非ディレクトリは無視される。
        try Data().write(to: layout.root.appending(component: "stray.caf"))

        // /var と /private/var のシンボリックリンク差を吸収して比較する。
        let pending = layout.pendingRecordings().map { $0.resolvingSymlinksInPath() }
        let expected = [cafA, cafB]
            .map { $0.resolvingSymlinksInPath() }
            .sorted { $0.path < $1.path }

        #expect(pending == expected)
    }

    @Test func pendingRecordingsIsEmptyWhenRootMissing() {
        let layout = SessionLayout(
            root: FileManager.default.temporaryDirectory
                .appending(component: "SessionLayoutTests-missing-\(UUID().uuidString)")
        )
        #expect(layout.pendingRecordings().isEmpty)
    }
}
