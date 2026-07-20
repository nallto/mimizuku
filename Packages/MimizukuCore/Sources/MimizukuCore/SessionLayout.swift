import Foundation

/// セッションの保存先レイアウト(ADR-0006)。
///
/// ```
/// <root>/<yyyyMMdd-HHmmss>/
///   mic.caf    → 変換後 mic.m4a
///   system.caf → 変換後 system.m4a
/// ```
///
/// ローカルファイル IO のみで UI/TCC 非依存(CI テスト可能)。メタデータファイルの
/// 形式は D2 / ADR-0007 で決定するまで置かない。
public struct SessionLayout: Sendable {
    /// セッションディレクトリ群の親(例: `~/Library/Application Support/Mimizuku/sessions`)。
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 既定の保存先(XDG Base Directory 準拠、ADR-0006)。
    /// データは `$XDG_DATA_HOME/mimizuku/sessions`(未設定/相対パスなら `~/.local/share`)。
    /// - Parameters は注入可能(テスト用)。既定は実プロセス環境と Home。
    public static func defaultLayout(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SessionLayout {
        let dataHome = xdgDataHome(environment: environment, homeDirectory: homeDirectory)
        return SessionLayout(root: dataHome.appending(components: "mimizuku", "sessions"))
    }

    /// `$XDG_DATA_HOME` を解決する。XDG 仕様どおり、未設定・空・相対パスは無視して
    /// `~/.local/share` へフォールバックする(絶対パスのみ有効)。
    static func xdgDataHome(environment: [String: String], homeDirectory: URL) -> URL {
        if let value = environment["XDG_DATA_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return homeDirectory.appending(components: ".local", "share")
    }

    /// セッションディレクトリ名(`yyyyMMdd-HHmmss`、ローカル時刻)。
    public static func directoryName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 録音ファイル名(変換前の CAF)。例: `mic.caf` / `system.caf`。
    public static func recordingFileName(for kind: StreamKind) -> String {
        switch kind {
        case .microphone: "mic.caf"
        case .systemAudio: "system.caf"
        }
    }

    /// セッション開始時刻からディレクトリを作成して返す。同名が既にあれば `-2` 以降を
    /// 付けて衝突を避ける(同一秒内の再開始)。
    public func createSessionDirectory(
        startedAt date: Date,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = Self.directoryName(for: date)
        var candidate = root.appending(component: name)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appending(component: "\(name)-\(suffix)")
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// AAC へ変換されずに残っている CAF を列挙する(クラッシュ回復対象、ADR-0006 の 6)。
    /// 返り値はパス昇順(決定的)。
    public func pendingRecordings(fileManager: FileManager = .default) -> [URL] {
        guard let sessions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return sessions
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap { dir in
                let contents = (try? fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                )) ?? []
                return contents.filter { $0.pathExtension == "caf" }
            }
            .sorted { $0.path < $1.path }
    }
}
