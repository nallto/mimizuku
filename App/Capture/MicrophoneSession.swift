import AVFoundation
import MimizukuCore
import os
import OSLog

/// 1 ストリーム分のマイク捕捉セッション。
///
/// 既定入力デバイスが録音中に切り替わると、`AVAudioEngine` は停止して
/// `AVAudioEngineConfigurationChange` を出すだけで自動再開しない。購読していなければ tap は
/// バッファを出さなくなるだけで、ストリームは finish も throw もせず無言で止まる
/// (docs/domain-pitfalls.md #14、`AudioSource` 契約違反)。本クラスは通知購読による再構築と、
/// 通知が出ない形の停止に対する時間駆動 watchdog の 2 本で検知する。
///
/// **キューを 2 本に分ける**(docs/domain-pitfalls.md #16、ADR-0016 決定9)。HAL 呼び出しは
/// 入力デバイスが不安定なとき分単位でブロックする(実測 129 秒)。監視と停止をブロックする
/// 経路に置くと、上限到達での失敗判定も利用者の停止も効かなくなる ―― 保証が必要な場面で
/// ちょうど失われる。
/// - `controlQueue`: 状態管理・停止監視・停止・失敗通知。ブロックする呼び出しを置かない。
/// - `buildQueue`: `AVAudioEngine` と HAL 呼び出し。ブロックしてよい。
///
/// `@unchecked Sendable` の正当化(ハード制約 #4、PR にも明記): DispatchQueue と
/// NotificationCenter(@Sendable クロージャ)へ self を渡すために Sendable 宣言が必要だが、
/// 可変状態はすべて「controlQueue 専有」か「buildQueue 専有」に分かれており、捕捉スレッドと
/// 共有するのはロックで保護された `CaptureArrivalRecorder` と世代番号だけである。非 Sendable な
/// `AVAudioEngine` は buildQueue から retireQueue へ**排他的に移譲**する(buildQueue 側で
/// `engine = nil` にしてから渡すため、以後 buildQueue は触らない)。通知トークンは buildQueue から
/// 出さない。コンパイラが検証できないだけでデータ競合は構造的に排除されている。アクター化しない理由: tap コールバックが任意スレッドから
/// 同期的に呼ばれ、HAL 照会も同期 API のため。
final class MicrophoneSession: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<TimestampedAudioBuffer, Error>.Continuation

    private let continuation: Continuation
    private let logger: Logger
    private let onStatus: @Sendable (MicCaptureStatus) -> Void
    private let controlQueue = DispatchQueue(label: "dev.nallto.Mimizuku.mic.control")
    private let buildQueue = DispatchQueue(label: "dev.nallto.Mimizuku.mic.build")
    /// 古いエンジンの後始末専用。返らない `stop()` をここへ隔離する(pitfalls #17)。
    private let retireQueue = DispatchQueue(label: "dev.nallto.Mimizuku.mic.retire")
    /// tap コールバック(任意スレッド)が読む現在の世代。
    private let currentGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// tap コールバック(任意スレッド)が書き、停止監視(controlQueue)が読む到着時刻。
    private let arrivals = CaptureArrivalRecorder()

    // MARK: controlQueue でのみ触る状態

    private var stallMonitor: CaptureStallMonitor?
    /// build が buildQueue で進行中か。進行中なら新たな再構築を投入しない
    /// (ブロックしている間に要求を積み上げても意味がなく、上限到達の判定だけを進める)。
    private var buildInFlight = false
    private var lastBuildError: String?
    private var reportedBlocked = false
    private var stopped = false

    // MARK: buildQueue でのみ触る状態

    private var engine: AVAudioEngine?
    /// 初回 build で固定される基準フォーマット(`AudioSource` 契約: ストリーム生涯で不変)。
    private var referenceFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    /// エンジンの世代。後始末待ちの古いエンジンの出力を捨てるために使う。
    private var generationCounter: UInt64 = 0

    init(
        continuation: Continuation,
        logger: Logger,
        onStatus: @escaping @Sendable (MicCaptureStatus) -> Void
    ) {
        self.continuation = continuation
        self.logger = logger
        self.onStatus = onStatus
    }

    // MARK: - ライフサイクル(controlQueue)

    func start() {
        controlQueue.async { [self] in
            guard !stopped else { return }
            startStallMonitor()
            runBuild(isInitial: true)
        }
    }

    func stop() {
        controlQueue.async { [self] in
            guard !stopped else { return }
            stopped = true
            stallMonitor?.cancel()
            logger.notice("microphone capture stopped")
            // teardown は buildQueue へ投げる。build がブロック中でも利用者を待たせない。
            buildQueue.async { [self] in teardown() }
        }
    }

    /// 再構築の上限に達した。無言ハングにせずストリームを失敗させる(fail-closed)。
    /// build がブロック中でもここは進む ―― それがキューを分けた理由。
    private func failStream(attempts: Int) {
        guard !stopped else { return }
        stopped = true
        stallMonitor?.cancel()
        logger.error("mic capture stalled; giving up after \(attempts, privacy: .public) rebuilds")
        continuation.finish(throwing: CaptureError.micCaptureStalled(
            attempts: attempts,
            lastError: lastBuildError
        ))
        buildQueue.async { [self] in teardown() }
    }

    /// 再構築がHAL内でブロックしている。**失敗させない** ―― ブロックは解ければ回復し、
    /// 実測では閾値をいくら置いてもわずかな差で外れる(docs/domain-pitfalls.md #16)。
    /// 代わりに状態を利用者へ見せ、見切りは停止操作に委ねる(ADR-0016 決定10)。
    private func noteBlocked(blockedSeconds: TimeInterval) {
        guard !stopped else { return }
        if !reportedBlocked {
            reportedBlocked = true
            let seconds = String(format: "%.1f", blockedSeconds)
            logger.notice("mic rebuild still blocked after \(seconds, privacy: .public)s")
        }
        onStatus(.reconnecting(blockedSeconds: blockedSeconds))
    }

    /// ブロックが解けた。「再接続中」の表示を下ろす。
    private func clearBlockedIfNeeded() {
        guard reportedBlocked else { return }
        reportedBlocked = false
        logger.notice("mic rebuild unblocked")
        onStatus(.normal)
    }

    // MARK: - 再構築の要求(controlQueue)

    private func requestRebuild(reason: String) {
        controlQueue.async { [self] in
            guard !stopped else { return }
            guard !buildInFlight else {
                // 進行中の build がブロックしている。要求は捨て、watchdog の判定に委ねる。
                logger.notice("mic rebuild already in flight: \(reason, privacy: .public)")
                return
            }
            logger.notice("rebuilding mic capture: \(reason, privacy: .public)")
            runBuild(isInitial: false)
        }
    }

    /// buildQueue で build を実行し、結果を controlQueue へ戻す。
    /// 非 Sendable な `AVAudioEngine` とエラーはキューを跨がせない。
    private func runBuild(isInitial: Bool) {
        buildInFlight = true
        // ブロックしうる区間に入る。以後は build 専用の期限で判定させる
        // (通常の 2/4/8 秒バックオフで殺さない。ADR-0016 決定10)。
        stallMonitor?.markBuildStarted()
        buildQueue.async { [self] in
            do {
                try build()
                controlQueue.async { [self] in
                    buildInFlight = false
                    lastBuildError = nil
                    stallMonitor?.markBuildFinished()
                    clearBlockedIfNeeded()
                    guard !stopped else {
                        // ブロック中に停止・失敗が確定していた。作ったものは畳む。
                        buildQueue.async { [self] in teardown() }
                        return
                    }
                    stallMonitor?.markStarted()
                }
            } catch {
                let message = error.localizedDescription
                let phase = isInitial ? "start" : "rebuild"
                logger.error("mic \(phase, privacy: .public) failed: \(message, privacy: .public)")
                teardown()
                if isInitial {
                    // 開始時の失敗は watchdog のエスカレーションを待たず即時に報告する
                    // (再構築で回復する見込みがなく、待つ分だけ原因が分かりにくくなる)。
                    // finish は冪等なので、controlQueue 側の停止と競合しても安全。
                    continuation.finish(throwing: error)
                }
                controlQueue.async { [self] in
                    buildInFlight = false
                    lastBuildError = message
                    stallMonitor?.markBuildFinished()
                    clearBlockedIfNeeded()
                    guard isInitial, !stopped else { return }
                    stopped = true
                    stallMonitor?.cancel()
                }
            }
        }
    }

    // MARK: - 構築と後始末(buildQueue。ブロックしてよい)

    private func build() throws {
        // **古いエンジンの後始末を先に行わない。** 自プロセスの process tap + aggregate device が
        // 既定出力デバイスを掴んでいる間、既定出力が切り替わると古いエンジンの `stop()` が
        // 返らなくなる(実測。docs/domain-pitfalls.md #17)。先に新しいエンジンを起動し、
        // 古い方は待たずに別で畳む ―― マイクの復旧を後始末に引きずらせない。
        logger.notice("mic build: querying input format")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // HAL 照会は捕捉開始時のみ、かつ main thread 以外で行う(domain-pitfalls #10)。
        // この 1 行と `engine.start()` が分単位でブロックしうる(#16)。
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            // 構成変更の直後は無効なフォーマットが返りうる。初回 build ではそのまま開始失敗、
            // 再構築中なら watchdog がバックオフつきで次の再試行を出す。
            throw CaptureError.micInputFormatUnavailable(
                sampleRate: inputFormat.sampleRate,
                channelCount: inputFormat.channelCount
            )
        }

        // 基準フォーマットは初回に固定し、以後の再構築でデバイス由来のフォーマットが
        // 変わったら基準へ変換して流す(`AudioSource` 契約。下流の録音ファイル・
        // AEC ポンプ・変換器は最初のバッファのフォーマットで固定されるため)。
        let reference = referenceFormat ?? inputFormat
        referenceFormat = reference
        guard let copier = BufferConverter(from: inputFormat, to: reference) else {
            throw CaptureError.converterUnavailable(from: inputFormat, to: reference)
        }

        let generation = nextGeneration()
        installTap(on: input, format: inputFormat, copier: copier, generation: generation)

        logger.notice("mic build: starting engine")
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            // 起動できなかった。古いエンジンもここで手放す(どちらも音を出していない)。
            retirePreviousEngine()
            throw error
        }
        // 起動できた。ここで初めて古いエンジンを手放し(無効化 + 後始末を投げる)、
        // そのうえで新しい世代を有効化する。順序を逆にすると新しい tap まで捨ててしまう。
        retirePreviousEngine()
        self.engine = engine
        activate(generation: generation)
        // 構成変更の購読は build 成功のたびに張り直す。エンジンは再構築で差し替わり、
        // 通知の object は post 元のエンジンなので、古い購読は二度と配信されない。
        installConfigurationObserver(for: engine)
        let hz = Int(inputFormat.sampleRate)
        let ch = Int(inputFormat.channelCount)
        let converted = inputFormat.sampleRate != reference.sampleRate
            || inputFormat.channelCount != reference.channelCount
        logger.notice(
            """
            mic capture started: \(hz, privacy: .public)Hz \(ch, privacy: .public)ch \
            converted=\(converted, privacy: .public)
            """
        )
    }

    /// tap を張る。世代チェックにより、後始末待ちの古いエンジンが出すバッファは流さない。
    /// 到着記録はコピー成功後に行う ―― 基準フォーマットへ変換できないバッファは「音声として
    /// 届いていない」と扱い、停止検知の対象にする(fail-closed)。
    private func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        copier: BufferConverter,
        generation: UInt64
    ) {
        let continuation = continuation
        let arrivals = arrivals
        let currentGeneration = currentGeneration
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard currentGeneration.withLock({ $0 }) == generation else { return }
            guard let copy = copier.convertedCopy(of: buffer) else { return }
            arrivals.note()
            continuation.yield(TimestampedAudioBuffer(
                buffer: copy,
                hostTime: TimestampedStreamSupport.seconds(from: when)
            ))
        }
    }

    /// 現在のエンジンを手放し、**後始末は待たずに**専用キューへ投げる。
    ///
    /// `engine.stop()` は、自プロセスの tap が既定出力デバイスを掴んでいる状態で出力が
    /// 切り替わると返らなくなる(実測 129 秒。docs/domain-pitfalls.md #17)。待つと復旧も停止も
    /// 巻き添えになるため、投げっぱなしにする。専用キューは直列なので、詰まっても
    /// スレッドが増え続けることはない。
    private func retirePreviousEngine() {
        // 手放した時点で無効化する。後始末待ちの古いエンジンが出すバッファは、
        // tap 側の世代判定(0 とは一致しない)で捨てられる。
        activate(generation: 0)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let retired = engine else { return }
        engine = nil
        let logger = logger
        retireQueue.async {
            logger.notice("mic retire: stopping previous engine")
            retired.stop()
            retired.inputNode.removeTap(onBus: 0)
            logger.notice("mic retire: previous engine released")
        }
    }

    /// 停止時の後始末。こちらも待たない(利用者の停止操作を HAL のブロックに巻き込まない)。
    private func teardown() {
        retirePreviousEngine()
    }

    /// 新しいエンジンへ割り当てる世代(1 起点)。有効化は起動成功後に行う。
    private func nextGeneration() -> UInt64 {
        generationCounter += 1
        return generationCounter
    }

    /// この世代の tap だけを通す。0 は「有効なエンジンなし」。
    private func activate(generation: UInt64) {
        currentGeneration.withLock { $0 = generation }
    }

    /// object を対象エンジンに限定する。nil で購読すると、将来追加する再生用エンジンの
    /// 構成変更でもマイクを再構築してしまうため、エンジンが無い状態では購読しない。
    private func installConfigurationObserver(for engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.requestRebuild(reason: "engine configuration changed")
        }
    }

    // MARK: - 停止検知(controlQueue)

    private func startStallMonitor() {
        let monitor = CaptureStallMonitor(
            queue: controlQueue,
            arrivals: arrivals,
            watchdog: CaptureStallWatchdog(),
            onRebuild: { [weak self] reason, _ in
                self?.requestRebuild(reason: "capture \(reason)")
            },
            onFail: { [weak self] attempts in
                self?.failStream(attempts: attempts)
            },
            onBlocked: { [weak self] blockedSeconds in
                self?.noteBlocked(blockedSeconds: blockedSeconds)
            }
        )
        stallMonitor = monitor
        monitor.start()
    }
}
