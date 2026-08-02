import AVFoundation
import MimizukuCore

// MARK: - 捕捉ソースの配線(モード別 + AEC)

extension AudioSessionController {
    /// モード別に捕捉ソースを配線し、AEC(#63/#64、ADR-0014)を挟む。
    /// - 両方: システム音声を far-end 参照に tee、マイクは処理後ストリーム。
    /// - マイク単体: 隠し参照 tap を far-end に使い、マイクを処理後ストリームで流す
    ///   (参照tapは録音・文字起こしに出さない ―― AEC-4)。参照を開始・復旧できなければ失敗。
    /// - システム音声のみ: near-end が無いため AEC は適用しない(従来どおり)。
    func makeInputs(
        for streams: [StreamKind],
        generation: UInt64
    ) async throws -> [StreamKind: any AudioSource] {
        let hasMic = streams.contains(.microphone)
        let hasSystem = streams.contains(.systemAudio)
        if hasMic, hasSystem {
            return try await makeBothInputs(generation: generation)
        }
        if hasMic {
            return try await makeMicrophoneOnlyInputs(generation: generation)
        }
        applyAecStatus(.notApplicable, for: generation)
        return [.systemAudio: SystemAudioTapSource()]
    }

    /// 「両方」モード: システム音声 tee(相手側の文字起こし・録音はそのまま)+ 処理後マイク。
    /// ブリッジ初期化に失敗した場合、raw micへフォールバックせず開始失敗にする。
    private func makeBothInputs(generation: UInt64) async throws -> [StreamKind: any AudioSource] {
        let mic = MicrophoneSource()
        let system = SystemAudioTapSource()
        let pump = makeAecPump(generation: generation)
        guard await pump.start() else {
            logger.error("aec unavailable; refusing unprocessed microphone")
            applyAecStatus(
                .failed(reason: "エコーキャンセルの初期化に失敗しました。"),
                for: generation
            )
            throw CaptureError.aecInitializationFailed
        }
        guard isCurrentSession(generation), !Task.isCancelled else {
            throw CancellationError()
        }
        applyAecStatus(.starting, for: generation)
        logger.notice("aec starting (both mode)")
        // DeferredAudioSource で包み、ストリーム生成(= HAL 照会・engine 起動を含む)を
        // ルーター Task(off-main)まで遅延する(domain-pitfalls #10)。
        return [
            .systemAudio: DeferredAudioSource(kind: .systemAudio) {
                pump.referenceTee(system.timestampedBuffers())
            },
            .microphone: DeferredAudioSource(kind: .microphone) {
                pump.processedCapture(from: mic.timestampedBuffers())
            }
        ]
    }

    /// 「マイク単体」モード(#64): 隠し参照 tap で far-end を供給し、マイクに AEC を効かせる。
    /// 参照 tap は録音・文字起こしに出さない(処理後マイクだけを流す)。
    ///
    /// **事前プローブはしない。** `SystemAudioProbe` は process tap を生成→即破棄するため、
    /// その直後に本番の参照 tap を作ると本番 tap が無音になり AEC が何も打ち消せない
    /// (両方モードにはこの事前プローブが無く、打ち消せている ―― 唯一の構造差)。参照 tap は
    /// `DeferredAudioSource` の中で直接起動し、両方モードと同一経路(本番 tap を直接消費)に
    /// 揃える。参照が使えない場合、マイク原音は正式音源へ流さず、5秒の期限内に
    /// 参照を得られなければセッション開始失敗にする。
    private func makeMicrophoneOnlyInputs(
        generation: UInt64
    ) async throws -> [StreamKind: any AudioSource] {
        let mic = MicrophoneSource()
        let pump = makeAecPump(generation: generation)
        guard await pump.start() else {
            logger.error("aec unavailable (mic-only); refusing raw microphone")
            applyAecStatus(
                .failed(reason: "エコーキャンセルの初期化に失敗しました。"),
                for: generation
            )
            throw CaptureError.aecInitializationFailed
        }
        guard isCurrentSession(generation), !Task.isCancelled else {
            throw CancellationError()
        }
        applyAecStatus(.starting, for: generation)
        logger.notice("aec starting (mic-only with hidden reference)")
        return [
            .microphone: DeferredAudioSource(kind: .microphone) {
                pump.processedCaptureWithReference(
                    mic: mic.timestampedBuffers(),
                    reference: { SystemAudioTapSource().timestampedBuffers() }
                )
            }
        ]
    }

    /// AEC ポンプの実行時状態を MainActor の診断状態へ反映する。
    private func makeAecPump(generation: UInt64) -> AecPump {
        AecPump(diagnostics: aecDiagnosticsRecorder) { [weak self] status in
            self?.applyAecRuntimeStatus(status, generation: generation)
        }
    }

    private func applyAecRuntimeStatus(_ status: AecRuntimeStatus, generation: UInt64) {
        // stop()はMainActor上で先にisRunningをfalseにする。遅れて到着したwatchdog通知で
        // 通常停止後の診断状態をfailedへ上書きしない。
        guard isCurrentSession(generation), isRunning else { return }
        switch status {
        case .active:
            logger.notice("aec active (reference available)")
            applyAecStatus(.active, for: generation)
        case .recovering:
            logger.notice("aec recovering (reference interrupted)")
            applyAecStatus(.recovering, for: generation)
        case .failed(.referenceStartTimedOut):
            logger.error("aec failed (reference start timed out)")
            applyAecStatus(
                .failed(reason: "参照音声を5秒以内に取得できませんでした。"),
                for: generation
            )
        case .failed(.referenceRecoveryTimedOut):
            logger.error("aec failed (reference recovery timed out)")
            applyAecStatus(
                .failed(reason: "参照音声を復旧できませんでした。"),
                for: generation
            )
        }
    }
}
