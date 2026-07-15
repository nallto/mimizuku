import AVFoundation
import CoreMedia
import MimizukuCore
import OSLog
import Speech

/// `SpeechAnalyzer` + `SpeechTranscriber`(Speech framework、macOS 26+)を
/// `TranscriptionEngine` 契約の裏に隠す本番実装。完全オンデバイス。
///
/// - 1 ソース = 1 セッション = 1 エンジン(`init(stream:)` で紐づけ)。App はマイクと
///   システム音声で 2 セッションを並行実行しうる(Slice 1 ではマイクのみ)。
/// - `.volatileResults` を有効化し、暫定結果(`isFinal == false`)に続いて確定版を流す。
///   消費側(`TranscriptLog`)が volatile→final の収束を担う。
/// - アセットはロケール別に数百 MB。`prepare(locale:)` で導入を保証する
///   (docs/domain-pitfalls.md #5)。ダウンロードは Apple のモデルのみを運び、音声・
///   文字起こしは載せない(ハード制約 #2 に抵触しない)。
///
/// actor にして、非 Sendable な Speech 型(`SpeechTranscriber` 等)の可変状態を隔離する。
actor SpeechEngine: TranscriptionEngine {
    private let stream: StreamKind
    private let logger: Logger

    /// `prepare(locale:)` で解決・保持するロケールと transcriber(セッション間で再利用)。
    private var locale: Locale?
    private var transcriber: SpeechTranscriber?

    init(stream: StreamKind) {
        self.stream = stream
        logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "speech.\(stream.rawValue)")
    }

    // MARK: - アセット

    /// 指定ロケールのモデルアセットが導入済みか(ダウンロード要否の判定用)。
    func isModelInstalled(for locale: Locale) async -> Bool {
        let resolved = await Self.resolvedLocale(for: locale)
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
    }

    /// `locale` 用のオンデバイスモデルを導入済みにする。未導入ならダウンロードして待つ。
    func prepare(locale: Locale) async throws {
        let resolved = await Self.resolvedLocale(for: locale)
        self.locale = resolved
        let transcriber = transcriber(for: resolved)

        // 何も導入不要なら nil。要導入なら数百 MB のダウンロードを待つ。
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let request {
            logger.info("downloading speech model asset…")
            try await request.downloadAndInstall()
            logger.info("speech model asset installed")
        }
    }

    /// 文字起こし器が扱える推奨入力フォーマット。`AudioSource` はこれに変換して流す
    /// (下流での再サンプリングを防ぐ)。`prepare` 後に呼ぶ。
    func bestInputFormat() async -> AVAudioFormat? {
        let locale = locale ?? Locale(identifier: "ja-JP")
        return await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [transcriber(for: locale)])
    }

    // MARK: - 文字起こし

    /// `segments(from:)` の返り型(行長を抑えるための別名。契約と同一の型)。
    private typealias SegmentStream = AsyncThrowingStream<TranscriptSegment, Error>

    nonisolated func segments(from source: any AudioSource) -> SegmentStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(source: source, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        source: any AudioSource,
        into continuation: SegmentStream.Continuation
    ) async throws {
        let locale = locale ?? Locale(identifier: "ja-JP")
        let transcriber = transcriber(for: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // 結果(volatile と final)を並行して消費し TranscriptSegment へマップする。
        // results は analyzer が終了(finalize)するまで完了しないため、給餌とは別タスクで待つ
        // (同一フローで待つとデッドロックする)。SpeechTranscriber は Sendable(SpeechModule)。
        let stream = stream
        let resultsTask = Task {
            for try await result in transcriber.results {
                continuation.yield(TranscriptSegment(
                    stream: stream,
                    text: String(result.text.characters),
                    isFinal: result.isFinal,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds
                ))
            }
        }

        try await analyzer.start(inputSequence: inputSequence)

        do {
            // 捕捉バッファを解析入力へ供給する。ソースが尽きる / キャンセルされるまで回る。
            for try await buffer in source.buffers() {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
            }
            inputContinuation.finish()
            // 残余を確定させ results を閉じる → resultsTask が完了する。
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultsTask.value
        } catch {
            // 停止 / キャンセル / 捕捉失敗: 入力を閉じ、結果消費を畳んで throw する。
            inputContinuation.finish()
            resultsTask.cancel()
            throw error
        }
    }

    // MARK: - Helpers

    private func transcriber(for locale: Locale) -> SpeechTranscriber {
        if let transcriber { return transcriber }
        let created = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        transcriber = created
        return created
    }

    /// Speech が対応する等価ロケールへ正規化(無ければ元のロケール)。
    private static func resolvedLocale(for locale: Locale) async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
    }
}
