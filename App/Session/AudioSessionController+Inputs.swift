import AVFoundation
import MimizukuCore

// MARK: - 捕捉ソースの配線(モード別 + AEC)

extension AudioSessionController {
    /// モード別に捕捉ソースを配線し、AEC(#63/#64、ADR-0013)を挟む。
    /// - 両方: システム音声を far-end 参照に tee、マイクは処理後ストリーム。
    /// - マイク単体: 隠し参照 tap を far-end に使い、マイクを処理後ストリームで流す
    ///   (参照 tap は録音・文字起こしに出さない ―― AEC-4)。参照が使えなければ AEC なし。
    /// - システム音声のみ: near-end が無いため AEC は適用しない(従来どおり)。
    func makeInputs(for streams: [StreamKind]) async -> [StreamKind: any AudioSource] {
        let hasMic = streams.contains(.microphone)
        let hasSystem = streams.contains(.systemAudio)
        if hasMic, hasSystem {
            return await makeBothInputs()
        }
        if hasMic {
            return await makeMicrophoneOnlyInputs()
        }
        applyAecStatus(.notApplicable)
        return [.systemAudio: SystemAudioTapSource()]
    }

    /// 「両方」モード: システム音声 tee(相手側の文字起こし・録音はそのまま)+ 処理後マイク。
    /// ブリッジ初期化に失敗したら従来経路(AEC なし)へフォールバックする(機能喪失にしない)。
    private func makeBothInputs() async -> [StreamKind: any AudioSource] {
        let mic = MicrophoneSource()
        let system = SystemAudioTapSource()
        let pump = makeAecPump()
        guard await pump.start() else {
            logger.error("aec unavailable, falling back to unprocessed capture")
            applyAecStatus(.degraded(reason: "エコーキャンセルの初期化に失敗しました。"))
            return [.microphone: mic, .systemAudio: system]
        }
        applyAecStatus(.starting)
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
    /// 揃える。参照が使えない(TCC 未許可・沈黙)場合は AEC が打ち消さないだけで、マイク録音・
    /// 文字起こしは `AecFeedScheduler` の安全弁で実時間継続する(graceful degradation)。
    /// 診断表示は初回 render 受信後だけ「有効」とし、参照失敗・沈黙時は「低下」へ更新する。
    private func makeMicrophoneOnlyInputs() async -> [StreamKind: any AudioSource] {
        let mic = MicrophoneSource()
        let pump = makeAecPump()
        guard await pump.start() else {
            logger.error("aec unavailable (mic-only), falling back to raw mic")
            applyAecStatus(.degraded(reason: "エコーキャンセルの初期化に失敗しました。"))
            return [.microphone: mic]
        }
        applyAecStatus(.starting)
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
    private func makeAecPump() -> AecPump {
        AecPump { [weak self] status in
            self?.applyAecRuntimeStatus(status)
        }
    }

    private func applyAecRuntimeStatus(_ status: AecRuntimeStatus) {
        switch status {
        case .active:
            logger.notice("aec active (reference available)")
            applyAecStatus(.active)
        case .degraded(.referenceStartTimedOut):
            logger.notice("aec degraded (reference start timed out)")
            applyAecStatus(.degraded(
                reason: "参照音声を取得できません。"
            ))
        case .degraded(.referenceUnavailable):
            logger.notice("aec degraded (reference unavailable)")
            applyAecStatus(.degraded(
                reason: "参照音声が利用できなくなりました。"
            ))
        }
    }
}
