import Foundation

/// AEC 診断データの保存先レイアウト(ADR-0015)。
///
/// ```
/// $XDG_STATE_HOME/mimizuku/aec-diagnostics/<yyyyMMdd-HHmmss>/
///   capture-raw.caf capture-processed.caf render-received.caf render-fed.caf
///   frames.jsonl speech.jsonl meta.json
/// ```
///
/// セッションデータ(`$XDG_DATA_HOME`、ADR-0006/0007)とはルートから分離する。
/// state は「ログ・履歴など移植する価値はないがセッションを跨いで残るデータ」の分類。
public struct AecDiagnosticsLayout: Sendable {
    /// 診断試行ディレクトリ群の親。
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let captureRawFileName = "capture-raw.caf"
    public static let captureProcessedFileName = "capture-processed.caf"
    public static let renderReceivedFileName = "render-received.caf"
    public static let renderFedFileName = "render-fed.caf"
    public static let framesFileName = "frames.jsonl"
    public static let speechFileName = "speech.jsonl"
    public static let metaFileName = "meta.json"

    /// 既定の保存先(`$XDG_STATE_HOME/mimizuku/aec-diagnostics`)。
    public static func defaultLayout(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AecDiagnosticsLayout {
        let stateHome = xdgStateHome(environment: environment, homeDirectory: homeDirectory)
        return AecDiagnosticsLayout(
            root: stateHome.appending(components: "mimizuku", "aec-diagnostics")
        )
    }

    /// `$XDG_STATE_HOME` を解決する。ADR-0006 と同じ規則 ―― 絶対パスのみ有効、
    /// 未設定・空・相対パスは既定 `~/.local/state` へフォールバックする。
    static func xdgStateHome(environment: [String: String], homeDirectory: URL) -> URL {
        if let value = environment["XDG_STATE_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return homeDirectory.appending(components: ".local", "state")
    }

    /// 試行ディレクトリを作成して返す。同名が既にあれば `-2` 以降を付けて衝突を避ける
    /// (既存ディレクトリへの上書きは禁止 ―― ADR-0015 の 2)。
    /// ディレクトリ名がそのまま試行 ID になる。
    public func createTrialDirectory(
        startedAt date: Date,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = SessionLayout.directoryName(for: date)
        var candidate = root.appending(component: name)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appending(component: "\(name)-\(suffix)")
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }
}
