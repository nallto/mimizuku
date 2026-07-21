import AVFoundation
import CoreMedia
import MimizukuCore
import OSLog
import Speech

/// `SpeechAnalyzer` + `SpeechTranscriber`(Speech framework、macOS 26+)を
/// `TranscriptionEngine` 契約の裏に隠す本番実装。完全オンデバイス。
///
/// - 1 ソース = 1 セッション = 1 エンジン。セグメントのストリームラベルは
///   `source.kind` に従う(エンジン自体はストリーム非依存)。App はマイクと
///   システム音声で 2 セッションを並行実行しうる(同時捕捉は S4)。
/// - `.volatileResults` を有効化し、暫定結果(`isFinal == false`)に続いて確定版を流す。
///   消費側(`TranscriptLog`)が volatile→final の収束を担う。
/// - アセットはロケール別に数百 MB。`prepare(locale:)` で導入を保証する
///   (docs/domain-pitfalls.md #5)。ダウンロードは Apple のモデルのみを運び、音声・
///   文字起こしは載せない(ハード制約 #2 に抵触しない)。
///
/// actor にして、非 Sendable な Speech 型(`SpeechTranscriber` 等)の可変状態を隔離する。
actor SpeechEngine: TranscriptionEngine {
    private let logger: Logger

    /// `prepare(locale:)` で解決・保持するロケール。transcriber はセッションごとに新規生成
    /// する(共有インスタンスを跨セッションで使い回すと、急速な stop→start で旧セッションの
    /// finalize と新セッションの start が重なりうるため)。モデルアセットはシステム管理で
    /// instance に紐づかない。
    private var locale: Locale?

    init() {
        logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "speech")
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
        let transcriber = Self.makeTranscriber(for: resolved)

        // 何も導入不要なら nil。要導入なら数百 MB のダウンロードを待つ。
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let request {
            logger.notice("downloading speech model asset…")
            try await request.downloadAndInstall()
            logger.notice("speech model asset installed")
        }
    }

    /// 文字起こし器が扱える推奨入力フォーマット。`AudioSource` はこれに変換して流す
    /// (下流での再サンプリングを防ぐ)。`prepare` 後に呼ぶ。
    func bestInputFormat() async -> AVAudioFormat? {
        let locale = locale ?? Locale(identifier: "ja-JP")
        return await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [Self.makeTranscriber(for: locale)])
    }

    // MARK: - 文字起こし

    /// `segments(from:)` の返り型(行長を抑えるための別名。契約と同一の型)。
    typealias SegmentStream = AsyncThrowingStream<TranscriptSegment, Error>

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
        let transcriber = Self.makeTranscriber(for: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // 結果(volatile と final)を並行して消費し TranscriptSegment へマップする。
        // results は analyzer が終了(finalize)するまで完了しないため、給餌とは別タスクで待つ
        // (同一フローで待つとデッドロックする)。SpeechTranscriber は Sendable(SpeechModule)。
        // セグメントのストリームラベルはソース由来(エンジンはストリーム非依存)。
        let stream = source.kind
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
            //
            // 完全無音(厳密ゼロ)のバッファは解析へ送らない ―― SpeechTranscriber は
            // 無音入力から短い幻聴セグメント(「あ」等)を生成することがある
            // (システム音声 tap の無音は厳密ゼロ。マイクはノイズフロアで非ゼロのため
            // 影響しない)。スキップで解析タイムラインが録音とずれないよう、全バッファに
            // 開始時刻を明示して供給する(TranscriptSegment.start/end の原点維持)。
            var framesElapsed: Int64 = 0
            for try await buffer in source.buffers() {
                let sampleRate = CMTimeScale(buffer.format.sampleRate)
                let startTime = CMTime(value: framesElapsed, timescale: max(sampleRate, 1))
                framesElapsed += Int64(buffer.frameLength)
                guard !Self.isAllZero(buffer) else { continue }
                inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
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

    /// 全サンプルが厳密にゼロか。PCM(int16 / float32)ではサンプル値 0 = 全バイト 0 なので
    /// フォーマット非依存にバイト走査で判定する(音があれば先頭付近で即 false)。
    private static func isAllZero(_ buffer: AVAudioPCMBuffer) -> Bool {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in list {
            guard let data = channel.mData else { continue }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for index in 0 ..< Int(channel.mDataByteSize) where bytes[index] != 0 {
                return false
            }
        }
        return true
    }

    private static func makeTranscriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Speech が対応する等価ロケールへ正規化(無ければ元のロケール)。
    private static func resolvedLocale(for locale: Locale) async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
    }
}
