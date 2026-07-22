import AVFoundation
import CoreAudio
import Foundation
import MimizukuCore
import OSLog

/// システム音声 tap の失敗理由。
enum SystemAudioTapError: Error, LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case tapFormatUnavailable
    case defaultOutputDeviceUnavailable
    case rebuildFailed(lastError: String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            "システム音声の捕捉に失敗しました(\(operation): \(status))。"
        case .tapFormatUnavailable:
            "システム音声 tap のフォーマットを取得できませんでした。"
        case .defaultOutputDeviceUnavailable:
            "既定の出力デバイスが見つかりませんでした。"
        case let .rebuildFailed(lastError):
            "システム音声捕捉の再構築に失敗しました: \(lastError)"
        }
    }
}

/// システム音声(全プロセスのミックス)を Core Audio process tap で捕捉し、
/// **native フォーマットのまま** PCM バッファを流す `AudioSource`。
///
/// 構成(docs/domain-pitfalls.md #1〜#3 を厳守):
/// - `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` → 以後 `isExclusive` に
///   触らない(#1: 意味反転の罠)。
/// - tap をサブ tap とする private aggregate device を既定出力デバイスに紐付け、
///   `AudioDeviceCreateIOProcIDWithBlock` で直接消費する(#2: AVAudioEngine の
///   向け直しは無言で失敗する)。
/// - ゼロサンプル watchdog(`ZeroSampleWatchdog`、バックオフ付き)の発火と既定出力
///   デバイスの変更で、tap + aggregate の**両方**を破棄・再作成する(#3)。再構築は
///   ソース内部で完結し、ストリームは切らない(録音・セッションを継続させる)。
///   CoreAudio API の失敗が連続した場合のみ throw する(正当な無音では殺さない)。
/// - フォーマットはストリーム生涯で固定: 初回 tap フォーマットを基準とし、再構築後に
///   デバイス由来でフォーマットが変わったら内部で基準へ変換して流す(下流の録音
///   ファイル・変換器を不変に保つ)。
/// - cold・単一消費者。ストリーム終了 / キャンセルで tap・aggregate・リスナーを
///   確実に解放する。
final class SystemAudioTapSource: AudioSource {
    let kind: StreamKind = .systemAudio

    private let logger = Logger(subsystem: "dev.nallto.Mimizuku", category: "capture.tap")

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        TimestampedStreamSupport.droppingTimestamps(timestampedBuffers())
    }

    /// AEC 経路用: 捕捉時刻付きで流す(消費者は AEC ポンプ ―― AEC-3。ADR-0013 の 4)。
    /// cold・単一消費者などの契約は `buffers()` と同じ。
    func timestampedBuffers() -> AsyncThrowingStream<TimestampedAudioBuffer, Error> {
        let logger = logger
        return AsyncThrowingStream { continuation in
            // TapSession はキュー直列化を根拠に @unchecked Sendable(宣言部の正当化
            // コメント参照)。ここでは生成して開始し、終了時に stop するだけ。
            let session = TapSession(continuation: continuation, logger: logger)
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }
}

/// 1 ストリーム分の tap セッション。生成・破棄・再構築は `controlQueue` に直列化し、
/// IO コールバックとその可変状態(watchdog・変換器)は `ioQueue` に閉じる。
///
/// `@unchecked Sendable` の正当化(ハード制約 #4、PR にも明記): 本クラスは
/// DispatchQueue(@Sendable クロージャ)へ self を渡すために Sendable 宣言が必要だが、
/// 可変状態はすべて「controlQueue 専有」「ioQueue 専有(差し替えは controlQueue から
/// `ioQueue.sync`)」のどちらかに直列化されており、コンパイラが検証できないだけで
/// データ競合は構造的に排除されている。アクター化しない理由: IOProc コールバックと
/// CoreAudio API(同期・ブロッキング)がディスパッチキュー前提のため。
private final class TapSession: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<TimestampedAudioBuffer, Error>.Continuation

    private let continuation: Continuation
    private let logger: Logger
    private let controlQueue = DispatchQueue(label: "dev.nallto.Mimizuku.tap.control")
    private let ioQueue = DispatchQueue(label: "dev.nallto.Mimizuku.tap.io")

    // MARK: controlQueue でのみ触る状態

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var stopped = false
    /// 初回 build で固定される基準フォーマット(以後のストリームはこれで流れる)。
    private var referenceFormat: AVAudioFormat?

    // MARK: ioQueue でのみ触る状態(build 完了時に controlQueue から sync で差し替える)

    private var ioTapFormat: AVAudioFormat?
    private var ioConverter: BufferConverter?
    private var watchdog = ZeroSampleWatchdog()

    init(continuation: Continuation, logger: Logger) {
        self.continuation = continuation
        self.logger = logger
    }

    // MARK: - ライフサイクル

    func start() {
        controlQueue.async { [self] in
            do {
                try build()
                installDeviceChangeListener()
            } catch {
                teardownDevices()
                continuation.finish(throwing: error)
                stopped = true
            }
        }
    }

    func stop() {
        controlQueue.async { [self] in
            guard !stopped else { return }
            stopped = true
            removeDeviceChangeListener()
            teardownDevices()
            logger.notice("system audio capture stopped")
        }
    }

    // MARK: - 構築と再構築(controlQueue)

    private func build() throws {
        // 1. process tap。イニシャライザが排他性を設定するため、以後 isExclusive に
        //    触らない(domain-pitfalls #1)。
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Mimizuku System Audio Tap"
        description.isPrivate = true
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "CreateProcessTap")
        tapID = newTapID

        // 2. tap の native フォーマット。
        var asbd = try readTapFormat()
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioTapError.tapFormatUnavailable
        }

        // 3. 既定出力デバイスへ紐付く private aggregate device(tap 自動開始 + drift 補正)。
        try createAggregate(tapUUID: description.uuid)

        // 4. IOProc で直接消費(AVAudioEngine は使わない、domain-pitfalls #2)。
        var newProcID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleIO(inInputData, at: inInputTime)
        }
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue, ioBlock),
            "CreateIOProcID"
        )
        procID = newProcID

        // 5. IO 側の状態を公開。基準フォーマットは初回に固定し、以後の再構築で
        //    フォーマットが変わったら基準へ変換して流す。
        let reference = referenceFormat ?? tapFormat
        referenceFormat = reference
        guard let converter = BufferConverter(from: tapFormat, to: reference) else {
            throw SystemAudioTapError.tapFormatUnavailable
        }
        // watchdog はここで初期化しない ―― 再構築のたびに新品にすると倍化した閾値が
        // 捨てられ、無音中に毎回初期間隔で再構築し続けてしまう(バックオフの意味が無い)。
        // 発火時のカウンタリセットと閾値倍化、非ゼロ時の初期化は watchdog 自身が行う。
        ioQueue.sync {
            ioTapFormat = tapFormat
            ioConverter = converter
        }

        // 6. 開始。
        try check(AudioDeviceStart(aggregateID, procID), "DeviceStart")
        let hz = Int(tapFormat.sampleRate)
        let ch = Int(tapFormat.channelCount)
        logger
            .notice(
                "system audio capture started: \(hz, privacy: .public)Hz \(ch, privacy: .public)ch"
            )
    }

    private func createAggregate(tapUUID: UUID) throws {
        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mimizuku Tap Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: 1
            ]]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregateID),
            "CreateAggregateDevice"
        )
        aggregateID = newAggregateID
    }

    /// watchdog / デバイス変更からの再構築要求。要求が連続しても再構築で watchdog が
    /// リセットされ次の発火まで間隔が空くため、明示的なコアレスは持たない
    /// (稀に連続 2 回再構築が走っても安全)。
    private func requestRebuild(reason: String) {
        controlQueue.async { [self] in
            guard !stopped else { return }
            rebuild(reason: reason)
        }
    }

    /// tap + aggregate の**両方**を破棄・再作成する(docs/domain-pitfalls.md #3)。
    /// CoreAudio API の失敗が連続した場合のみストリームを throw で終える。
    private func rebuild(reason: String) {
        guard !stopped else { return }
        // notice: 無音でも起こりうる想定内イベント(Logger.warning は Error 種別で
        // 記録されるため使わない)。永続化はされるので実地の劣化診断には残る。
        // 本物の失敗(再構築失敗)は下の error のまま。
        logger.notice("rebuilding system audio tap: \(reason, privacy: .public)")
        var lastError: any Error = SystemAudioTapError.rebuildFailed(lastError: "unknown")
        for attempt in 1 ... 3 {
            teardownDevices()
            do {
                try build()
                return
            } catch {
                lastError = error
                let reason = error.localizedDescription
                logger.error("rebuild attempt \(attempt) failed: \(reason, privacy: .public)")
            }
        }
        stopped = true
        removeDeviceChangeListener()
        teardownDevices()
        continuation.finish(
            throwing: SystemAudioTapError.rebuildFailed(lastError: lastError.localizedDescription)
        )
    }

    private func teardownDevices() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - 既定出力デバイスの変更監視(controlQueue)

    private func installDeviceChangeListener() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.requestRebuild(reason: "default output device changed")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            controlQueue,
            listener
        )
        if status == noErr {
            deviceListener = listener
        } else {
            // 監視に失敗しても捕捉自体は続ける。デバイス変更後にゼロサンプルが続く形の
            // 障害なら watchdog が拾うが、IOProc 自体が止まる形は検知できない
            // (稀なフォールバック経路として許容し、ログに残す)。
            logger.error("failed to observe default output device: \(status, privacy: .public)")
        }
    }

    private func removeDeviceChangeListener() {
        guard let deviceListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            controlQueue,
            deviceListener
        )
        self.deviceListener = nil
    }

    // MARK: - IO(ioQueue)

    private func handleIO(
        _ inputData: UnsafePointer<AudioBufferList>,
        at inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let tapFormat = ioTapFormat, let converter = ioConverter else { return }

        // ゼロサンプル watchdog(docs/domain-pitfalls.md #3)。float32 前提、
        // それ以外のフォーマットでは判定をスキップする。
        let isFloat = tapFormat.commonFormat == .pcmFormatFloat32
        if isFloat {
            let observation = TapBufferSupport.zeroObservation(of: inputData)
            if watchdog.observe(
                isAllZero: observation.isAllZero,
                frames: observation.samples / max(Int(tapFormat.channelCount), 1),
                sampleRate: tapFormat.sampleRate
            ) {
                // 注: observe が true を返した時点で閾値はバックオフ済み(次回発火用)。
                requestRebuild(reason: "zero-sample watchdog fired")
            }
        }

        // native → 基準フォーマットの独立コピー(初回構成では同一フォーマットの複写)。
        guard let raw = TapBufferSupport.makeBuffer(from: inputData, format: tapFormat),
              let copy = converter.convertedCopy(of: raw)
        else {
            return
        }
        continuation.yield(TimestampedAudioBuffer(
            buffer: copy,
            hostTime: TimestampedStreamSupport.seconds(from: inputTime.pointee)
        ))
    }

    // MARK: - CoreAudio ヘルパー(controlQueue)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemAudioTapError.coreAudio(operation: operation, status: status)
        }
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            "ReadTapFormat"
        )
        return asbd
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = Self.defaultOutputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            ),
            "ReadDefaultOutputDevice"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw SystemAudioTapError.defaultOutputDeviceUnavailable
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CFString プロパティは Unmanaged で受ける(CFString 変数への直接ポインタ形成は
        // オブジェクト参照を壊しうる)。Get 系プロパティは retained で返るため takeRetained。
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &uidRef) { pointer in
            try check(
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer),
                "ReadDeviceUID"
            )
        }
        guard let uid = uidRef?.takeRetainedValue() else {
            throw SystemAudioTapError.defaultOutputDeviceUnavailable
        }
        return uid as String
    }
}
