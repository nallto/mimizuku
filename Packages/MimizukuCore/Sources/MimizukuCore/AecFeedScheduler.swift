import Foundation

/// AEC ポンプの capture / render 給餌順と可用性状態を決める純ロジック。
///
/// マイク原音にはスピーカー再生中のシステム音声が含まれ得るため、正式なマイク音源として
/// 出力してよいのは、対応する render があり APM を通せる capture だけである。
///
/// - 初回 render 前の capture は保留せず、原音を同長の無音へ置き換える。
/// - 初回 render が `referenceStartTimeout` 内に来なければ開始失敗にする。
/// - 稼働後に render の対応が `holdTimeout` を超えて途切れたら `recovering` へ移る。
/// - `recovering` 中の capture も無音へ置き換え、render が戻れば新しい同期 epoch で復帰する。
/// - 復旧が `referenceRecoveryTimeout` を超えたら失敗にする。
/// - セッション終了時の drain は状態遷移を起こさず、残余 capture の原音を破棄する。
///
/// actor への到着順はタスクスケジューリングで入れ替わるため、AEC 可否の判定には各
/// フレームの host time と render フロンティアを使う。
public struct AecFeedScheduler: Sendable {
    public enum State: Sendable, Equatable {
        case waitingForReference
        case active
        case recovering
        case failed(FailureReason)
    }

    public enum FailureReason: Sendable, Equatable {
        case referenceStartTimedOut
        case referenceRecoveryTimedOut
    }

    public enum Transition: Sendable, Equatable {
        case none
        case activated
        case recovering
        case recovered
        case failed(FailureReason)
    }

    /// capture の扱い。`.silence` は原音を捨て、同じ長さの無音で時間軸だけを維持する。
    public enum Processing: Sendable, Equatable {
        case aec
        case silence
    }

    public struct Release: Sendable, Equatable {
        public let frame: AecFrame
        public let processing: Processing

        public init(frame: AecFrame, processing: Processing) {
            self.frame = frame
            self.processing = processing
        }
    }

    /// 保留上限超過で破棄した capture(#75 の診断対象 ―― 正式音源へ出ないまま
    /// 失われるため、元 hostTime を保持して観測可能にする)。
    public struct HeldOverflowDrop: Sendable, Equatable {
        public let firstHostTime: TimeInterval
        public let lastHostTime: TimeInterval
        public let frameCount: Int

        public init(firstHostTime: TimeInterval, lastHostTime: TimeInterval, frameCount: Int) {
            self.firstHostTime = firstHostTime
            self.lastHostTime = lastHostTime
            self.frameCount = frameCount
        }
    }

    /// active 中に対応 render を待つ実時間。超過すると復旧待ちへ移る。
    public let holdTimeout: TimeInterval
    public let frameDuration: TimeInterval
    /// active 中のcapture保留上限。超過分は正式音源へ出さず破棄する。
    public let maxHeldFrames: Int
    /// 初回 render の待機期限。既定5秒は実測の正常起動遅延約1.2秒に十分な余裕を持つ。
    public let referenceStartTimeout: TimeInterval
    /// 一時停止後に render が戻るまでの期限。
    public let referenceRecoveryTimeout: TimeInterval

    private struct Held: Sendable {
        var frame: AecFrame
        var arrivedAt: TimeInterval
    }

    private var held: [Held] = []
    private var startupBeganAt: TimeInterval?
    private var recoveryBeganAt: TimeInterval?

    /// 現在の同期 epoch の初回 render 時刻。これより古い capture は到着順にかかわらず破棄。
    public private(set) var renderEpochStartTime: TimeInterval?
    public private(set) var renderFrontier: TimeInterval?
    public private(set) var state: State = .waitingForReference

    public var heldCount: Int { held.count }
    public private(set) var discardedFrames: Int = 0
    public private(set) var droppedHeldFrames: Int = 0
    public private(set) var recoveryCount: Int = 0

    public init(
        holdTimeout: TimeInterval = 0.2,
        frameDuration: TimeInterval = 480.0 / 48000.0,
        maxHeldFrames: Int = 400,
        referenceStartTimeout: TimeInterval = 5.0,
        referenceRecoveryTimeout: TimeInterval = 5.0
    ) {
        precondition(holdTimeout >= 0 && frameDuration > 0 && maxHeldFrames > 0)
        precondition(referenceStartTimeout > 0 && referenceRecoveryTimeout > 0)
        self.holdTimeout = holdTimeout
        self.frameDuration = frameDuration
        self.maxHeldFrames = maxHeldFrames
        self.referenceStartTimeout = referenceStartTimeout
        self.referenceRecoveryTimeout = referenceRecoveryTimeout
    }

    /// watchdog の起点。capture が先に来た場合も `hold` が同じ起点を補完する。
    public mutating func begin(at now: TimeInterval) {
        guard startupBeganAt == nil else { return }
        startupBeganAt = now
    }

    /// 有効な render フレーム列を受信したことを通知する。
    ///
    /// `recovered` の場合、呼び出し側は APM・aligner を新しい epoch 用にリセットしてから、
    /// この render を給餌する。
    @discardableResult
    public mutating func advanceRenderFrontier(
        startingAt firstFrameHostTime: TimeInterval,
        to lastFrameHostTime: TimeInterval
    ) -> Transition {
        if case .failed = state { return .none }

        let transition: Transition
        switch state {
        case .waitingForReference:
            transition = .activated
            renderEpochStartTime = firstFrameHostTime
            renderFrontier = nil
        case .recovering:
            transition = .recovered
            renderEpochStartTime = firstFrameHostTime
            renderFrontier = nil
            recoveryBeganAt = nil
        case .active:
            transition = .none
        case .failed:
            return .none
        }

        state = .active
        let end = lastFrameHostTime + frameDuration
        renderFrontier = max(renderFrontier ?? end, end)
        return transition
    }

    /// 参照ストリームの中断を通知する。開始待ちでは期限まで再試行を許し、稼働後は
    /// `recovering` へ移る。確定失敗は watchdog の期限超過で決める。
    @discardableResult
    public mutating func markReferenceInterrupted(at now: TimeInterval) -> Transition {
        switch state {
        case .waitingForReference:
            return .none
        case .active:
            enterRecovery(at: now)
            return .recovering
        case .recovering, .failed:
            return .none
        }
    }

    @discardableResult
    public mutating func hold(_ frame: AecFrame, arrivedAt now: TimeInterval) -> HeldOverflowDrop? {
        if startupBeganAt == nil {
            startupBeganAt = now
        }
        held.append(Held(frame: frame, arrivedAt: now))
        guard held.count > maxHeldFrames else { return nil }
        let overflow = held.count - maxHeldFrames
        droppedHeldFrames += overflow
        discardedFrames += overflow
        let dropped = held.prefix(overflow)
        let drop = HeldOverflowDrop(
            firstHostTime: dropped.first?.frame.hostTime ?? frame.hostTime,
            lastHostTime: dropped.last?.frame.hostTime ?? frame.hostTime,
            frameCount: overflow
        )
        held.removeFirst(overflow)
        return drop
    }

    /// 現在処理できる capture を解放する。開始・復旧待ちと failed の capture は
    /// `.silence` として即時解放し、raw backlog を作らない。
    public mutating func release(now: TimeInterval) -> [Release] {
        _ = checkDeadline(now: now)

        if state == .waitingForReference || state == .recovering || isFailed {
            return silenceAllHeld()
        }

        var released: [Release] = []
        while let first = held.first {
            if isBeforeRenderEpoch(first.frame) {
                released.append(silenceFirst())
                continue
            }

            let required = first.frame.hostTime + frameDuration
            let coveredByRender = renderFrontier.map { required <= $0 } ?? false
            if coveredByRender {
                released.append(Release(frame: first.frame, processing: .aec))
                held.removeFirst()
                continue
            }

            if now - first.arrivedAt >= holdTimeout {
                enterRecovery(at: now)
                released.append(contentsOf: silenceAllHeld())
            }
            break
        }
        return released
    }

    /// 開始・復旧期限を評価する。watchdog からcapture到着と独立して呼ぶ。
    @discardableResult
    public mutating func checkDeadline(now: TimeInterval) -> Transition {
        switch state {
        case .waitingForReference:
            guard let startupBeganAt,
                  now - startupBeganAt >= referenceStartTimeout
            else { return .none }
            return fail(.referenceStartTimedOut)
        case .recovering:
            guard let recoveryBeganAt,
                  now - recoveryBeganAt >= referenceRecoveryTimeout
            else { return .none }
            return fail(.referenceRecoveryTimedOut)
        case .active, .failed:
            return .none
        }
    }

    /// セッション終了専用。実行時状態を変えずに残余を破棄する。
    public mutating func drainForShutdown() -> [Release] {
        silenceAllHeld()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private mutating func enterRecovery(at now: TimeInterval) {
        guard state == .active else { return }
        state = .recovering
        recoveryBeganAt = now
        renderEpochStartTime = nil
        renderFrontier = nil
        recoveryCount += 1
    }

    private mutating func fail(_ reason: FailureReason) -> Transition {
        state = .failed(reason)
        return .failed(reason)
    }

    private func isBeforeRenderEpoch(_ frame: AecFrame) -> Bool {
        guard let renderEpochStartTime else { return true }
        return frame.hostTime < renderEpochStartTime
    }

    private mutating func silenceFirst() -> Release {
        let first = held.removeFirst()
        discardedFrames += 1
        return Release(frame: first.frame, processing: .silence)
    }

    private mutating func silenceAllHeld() -> [Release] {
        var releases: [Release] = []
        releases.reserveCapacity(held.count)
        while !held.isEmpty {
            releases.append(silenceFirst())
        }
        return releases
    }
}
