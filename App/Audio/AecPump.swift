import AVFoundation
import MimizukuCore
import OSLog

/// WebRTC AEC3 のライブ適用ポンプ(#63 / #64、ADR-0013)。
///
/// far-end(システム音声 tap)を参照として取り込みつつ、near-end(マイク)を
/// 処理して「処理後ストリーム」を返す。処理後音声が文字起こしと録音の両方に流れる
///
/// - 内部フォーマットは 48kHz / mono / int16 / 10ms(ブリッジ契約)。入出力の変換は
///   遅延生成の `BufferConverter`(最初のバッファのフォーマットから確定)。
/// - 給餌順はホストタイムでマージする(`AecFeedScheduler` ―― 到着順給餌だと実 render が
///   系統的に破棄される。#63 の申し送り)。
/// - tap 中断中はマイク原音を同長の無音へ置換し、参照復帰時に同期epochとAPMを
///   リセットして再収束させる。期限超過はセッション失敗とする。
/// - ドリフトは計測して notice ログに残すのみ。補正の適用は soak で残留エコーの増悪が
///   観測された場合の後続対応(単点推定のフラッピング回避 ―― #63 の申し送り)。
/// - マイク経路の処理失敗は無言で欠損させず、処理後ストリームを throw で畳んで
///   セッション全体を止める(既存原則)。
actor AecPump {
    // 以下の stored property の一部は同一ファイル外の extension(+Diagnostics /
    // +Support)から使うため private を付けない。actor 分離が排他を担保する。
    let bridge = AudioProcessingBridge()
    let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "aec")
    let statusHandler: @MainActor @Sendable (AecRuntimeStatus) -> Void
    let shutdownGate = AecShutdownGate()
    /// 診断シンク(#75 / ADR-0015)。nil なら記録は完全に無効(RMS 計算も行わない)。
    /// 投入は非ブロッキングで、書き込みは専用 writer Task が行う(観測がタイミングを
    /// 変えないため)。
    let diagnostics: AecDiagnosticsRecorder?

    var renderFramer = AecFramer()
    var captureFramer = AecFramer()
    // 実測ホストタイムはジッタを持つため、サンプルクロック由来の連続タイムラインへ
    // 正規化してから使う(AecTimeline のコメント参照 ―― ジッタをそのまま framer へ
    // 渡すと不連続破棄が頻発し、マイクが約 5% 欠けて AEC がロックしない実測)。
    // 閾値: capture(マイク)はエンジン継続中に本物の欠落が起きない前提で緩め、
    // render(tap)は再構築の欠落(数十 ms〜)をリベースとして検出できるよう狭める。
    var captureTimeline = AecTimeline(rebaseThreshold: 0.25)
    var renderTimeline = AecTimeline(rebaseThreshold: 0.05)
    var aligner = AecAligner()
    var scheduler = AecFeedScheduler()
    var drift = AecDriftDiagnostics()
    private var renderConverter: BufferConverter?
    private var captureConverter: BufferConverter?
    var output: AsyncThrowingStream<AecFrame, Error>.Continuation?
    var started = false
    var processedFrames = 0
    var silencedFrames = 0
    /// `.active` は初回 render 受信時ではなく、対応する capture を実際に APM へ
    /// 入れた時点で一度だけ通知する。
    var reportedActive = false
    /// 復旧時に古い同期epochをAPMへ持ち越さないため、次の有効render受信前に
    /// bridge/aligner/framerを一度だけ初期化する。
    private var recoveryResetPending = false
    var reportedFailure = false
    /// 診断: capture 側の正規化タイムラインの現在端(初回 render とのオフセット計測用)。
    private var captureFrontierTime: TimeInterval?
    private var loggedFirstRender = false
    /// 同期 epoch(復旧リセットごとに +1)。診断レコードの対応付けに使う。
    var epoch = 0
    /// capture 解放順の連番(capture-raw / capture-processed CAF の位置)。
    var captureFrameIndex = 0
    /// `.silence` を含め output へ実際に yield したフレーム数(Speech への供給順)。
    var outputFrameIndex = 0
    /// framer 通過後の実参照フレーム連番(render-received CAF の位置)。
    var renderFrameIndex = 0
    /// APM への給餌順連番 = APM 内部時間の正典(render-fed CAF の位置)。
    var fedIndex = 0

    /// ブリッジ契約の内部フォーマット。
    static let aecFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48000,
        channels: 1,
        interleaved: true
    )

    init(
        diagnostics: AecDiagnosticsRecorder? = nil,
        statusHandler: @escaping @MainActor @Sendable (AecRuntimeStatus) -> Void = { _ in }
    ) {
        self.diagnostics = diagnostics
        self.statusHandler = statusHandler
    }

    /// APM を初期化する。失敗時はfalse(呼び出し側はrawへ戻さず開始失敗にする)。
    func start() -> Bool {
        guard Self.aecFormat != nil, bridge.initializeProcessing() else {
            logger.error("aec bridge initialization failed")
            return false
        }
        scheduler.begin(at: Self.currentHostSeconds())
        started = true
        return true
    }

    // MARK: - 取り込み(actor 内)

    func setOutput(_ continuation: AsyncThrowingStream<AecFrame, Error>.Continuation) {
        output = continuation
    }

    /// 隠し参照tapのストリーム中断(mic-only)。開始待ちでは期限まで再生成を許し、
    /// 稼働後はrecoveringへ移る。いずれもマイク原音は正式出力へ流さない。
    func noteReferenceInterrupted(_ error: (any Error)?) async {
        guard started else { return }
        if let error {
            logger.notice(
                "aec hidden reference interrupted: \(error.localizedDescription, privacy: .public)"
            )
        } else {
            logger.notice("aec hidden reference interrupted without error")
        }
        let now = Self.currentHostSeconds()
        note(.event(.init(
            kind: .referenceInterrupted,
            hostTime: now,
            epoch: epoch,
            message: error?.localizedDescription
        )))
        let transition = scheduler.markReferenceInterrupted(at: now)
        if transition == .recovering {
            recoveryResetPending = true
            reportedActive = false
            note(.event(.init(kind: .recoveryEntered, hostTime: now, epoch: epoch)))
            await statusHandler(.recovering)
        }
        await releaseAndProcess()
    }

    func shouldRetryReference() -> Bool {
        guard started else { return false }
        if case .failed = scheduler.state { return false }
        return true
    }

    /// capture到着と独立して期限超過を検出し、rawへ戻さず明示エラーで終了する。
    func checkReferenceDeadline() async -> Bool {
        guard started, !shutdownGate.isSet, !Task.isCancelled else { return false }
        let transition = scheduler.checkDeadline(now: Self.currentHostSeconds())
        guard case let .failed(reason) = transition else { return true }
        // deadline判定と同時に利用者停止が入った場合は、failed通知より停止を優先する。
        guard !shutdownGate.isSet, !Task.isCancelled else { return false }
        await failForUnavailableReference(reason)
        return false
    }

    func ingestRender(_ item: TimestampedAudioBuffer) async {
        guard started, let format = Self.aecFormat else { return }
        if case .failed = scheduler.state { return }
        if recoveryResetPending {
            resetForRecovery()
            recoveryResetPending = false
        }
        if renderConverter == nil {
            renderConverter = BufferConverter(from: item.buffer.format, to: format)
        }
        guard let converter = renderConverter,
              let converted = converter.convertedCopy(of: item.buffer),
              let samples = Self.int16Samples(of: converted)
        else {
            // 参照の単発欠落は aligner の無音充填で吸収される(致命にしない)。
            return
        }
        drift.recordRender(sampleCount: samples.count, hostTime: item.hostTime)
        let normalization = renderTimeline.normalize(
            hostTime: item.hostTime,
            sampleCount: samples.count
        )
        noteInputChunk(
            .render,
            observed: item.hostTime,
            normalization: normalization,
            sampleCount: samples.count,
            driftPPM: drift.renderPPM
        )
        let time = normalization.hostTime
        logFirstRenderIfNeeded(at: time)
        let framed = renderFramer.append(samples: samples, hostTime: time)
        if let discarded = framed.discarded {
            noteFramerDiscard(.renderFramerDiscarded, discarded)
        }
        let frames = framed.frames
        guard let first = frames.first, let last = frames.last else { return }
        for frame in frames {
            recordRenderReceived(frame)
            renderFrameIndex += 1
            noteAlignerEvents(aligner.appendRender(frame))
        }
        let transition = scheduler.advanceRenderFrontier(
            startingAt: first.hostTime,
            to: last.hostTime
        )
        if transition == .recovered {
            logger.notice("aec reference recovered; waiting for processed capture")
        }
        await releaseAndProcess()
    }

    func ingestCapture(_ item: TimestampedAudioBuffer) async {
        guard started, let format = Self.aecFormat else { return }
        if captureConverter == nil {
            captureConverter = BufferConverter(from: item.buffer.format, to: format)
        }
        guard let converter = captureConverter,
              let converted = converter.convertedCopy(of: item.buffer),
              let samples = Self.int16Samples(of: converted)
        else {
            // マイク経路の欠損は許さない(録音は処理後ストリームから作られる)。
            await finishCapture(error: CaptureError.aecProcessingFailed)
            return
        }
        drift.recordCapture(sampleCount: samples.count, hostTime: item.hostTime)
        let normalization = captureTimeline.normalize(
            hostTime: item.hostTime,
            sampleCount: samples.count
        )
        noteInputChunk(
            .capture,
            observed: item.hostTime,
            normalization: normalization,
            sampleCount: samples.count,
            driftPPM: drift.capturePPM
        )
        let time = normalization.hostTime
        captureFrontierTime = time + Double(samples.count) / 48000
        let now = Self.currentHostSeconds()
        let framed = captureFramer.append(samples: samples, hostTime: time)
        if let discarded = framed.discarded {
            noteFramerDiscard(.captureFramerDiscarded, discarded)
        }
        for frame in framed.frames {
            if let drop = scheduler.hold(frame, arrivedAt: now) {
                note(.event(.init(
                    kind: .heldCaptureDropped,
                    firstHostTime: drop.firstHostTime,
                    lastHostTime: drop.lastHostTime,
                    frameCount: drop.frameCount,
                    epoch: epoch
                )))
            }
        }
        await releaseAndProcess()
    }

    private func releaseAndProcess() async {
        let now = Self.currentHostSeconds()
        let previousState = scheduler.state
        let releases = scheduler.release(now: now)
        if previousState == .active, scheduler.state == .recovering {
            recoveryResetPending = true
            reportedActive = false
            note(.event(.init(kind: .recoveryEntered, hostTime: now, epoch: epoch)))
        }
        var becameActive = false
        for release in releases {
            if release.processing == .silence {
                emitSilenced(release.frame)
                continue
            }
            guard await processAndEmit(release.frame) else { return }
            if !reportedActive {
                reportedActive = true
                becameActive = true
            }
        }
        // 音声フレームを順序どおり出力してから MainActor へ通知する。通知 await 中の
        // actor 再入で後続 capture が先に出力される逆転を防ぐ。
        if becameActive {
            await statusHandler(.active)
        }
        if previousState == .active, scheduler.state == .recovering {
            await statusHandler(.recovering)
        }
        if case let .failed(reason) = scheduler.state, !reportedFailure {
            await failForUnavailableReference(reason)
        }
    }

    /// セッション先頭のストリーム間アンカー差の実測(#63 のパターン切り分け用)。
    /// 0 近傍が期待値。大きな正負はタイムスタンプ意味差/ウォームアップ誤差のサイン。
    private func logFirstRenderIfNeeded(at time: TimeInterval) {
        guard !loggedFirstRender else { return }
        loggedFirstRender = true
        let deltaMs = Int(((captureFrontierTime ?? time) - time) * 1000)
        let held = scheduler.heldCount
        logger.notice(
            """
            aec first render: capture frontier vs render start = \
            \(deltaMs, privacy: .public)ms held=\(held, privacy: .public)
            """
        )
        note(.event(.init(
            kind: .firstRender,
            hostTime: time,
            deltaMs: Double(deltaMs),
            epoch: epoch
        )))
    }
}
