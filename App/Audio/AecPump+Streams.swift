import AVFoundation
import MimizukuCore

// MARK: - ストリーム配線(nonisolated アダプタ)

extension AecPump {
    /// far-end 参照の tee: システム音声を取り込みつつ、バッファをそのまま下流
    /// (相手側の文字起こし・録音)へ流す。取り込みは読み取りのみ(独立コピーへ変換)で、
    /// 下流も読み取りのみのため共有読み取りは安全。「両方」モードのシステム音声側。
    nonisolated func referenceTee(
        _ upstream: AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await item in upstream {
                        await self.ingestRender(item)
                        // バッファは独立コピーの単一系列(TimestampedAudioBuffer の
                        // 正当化コメント参照)。
                        nonisolated(unsafe) let buffer = item.buffer
                        continuation.yield(buffer)
                    }
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        // 選択されたシステム音声の予期しない終了は、マイクだけを残さず
                        // セッション全体へ明示的に伝播する。
                        continuation.finish(
                            throwing: CaptureError.sourceEndedUnexpectedly(.systemAudio)
                        )
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// near-end(マイク)を AEC 処理し、処理後バッファ(48kHz/mono/int16)を流す。
    /// far-end 参照は別経路(`referenceTee`)で供給される「両方」モード用。
    nonisolated func processedCapture(
        from upstream: AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        makeProcessedStream(mic: upstream, reference: nil)
    }

    /// マイク単体モード用: near-end(マイク)を AEC 処理しつつ、far-end 参照を**隠し tap**
    /// から取り込む(参照は録音・文字起こしには出さない ―― AEC-4。ADR-0013 の 4)。
    /// 参照ストリームの失敗は AEC の劣化にとどめ、マイク(処理後)は流し続ける
    /// (graceful degradation ―― TCC 未許可・tap 沈黙でも録音・文字起こしを止めない。
    /// 参照が来なければ scheduler の安全弁が実時間で素通し解放する)。
    /// `reference` は消費開始まで tap を生成しない遅延クロージャ(off-main で評価)。
    nonisolated func processedCaptureWithReference(
        mic: AsyncThrowingStream<TimestampedAudioBuffer, Error>,
        reference: @escaping @Sendable () -> AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        makeProcessedStream(mic: mic, reference: reference)
    }

    private nonisolated func makeProcessedStream(
        mic: AsyncThrowingStream<TimestampedAudioBuffer, Error>,
        reference: (@Sendable () -> AsyncThrowingStream<TimestampedAudioBuffer, Error>)?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (frames, framesContinuation) = AsyncThrowingStream.makeStream(of: AecFrame.self)
        // 給餌タスク: 出力先を登録してから取り込む(登録前のフレーム欠落を防ぐ順序)。
        let feedTask = Task {
            await self.setOutput(framesContinuation)
            await self.consumeCapture(mic)
        }
        // 隠し参照(mic-only)。参照 tap の失敗はマイク経路を止めず、AEC の劣化にとどめる。
        let referenceTask = reference.map { make in
            Task { await self.consumeHiddenReference(make) }
        }
        return AsyncThrowingStream { continuation in
            let mapTask = Task {
                do {
                    for try await frame in frames {
                        guard let buffer = Self.makeBuffer(from: frame) else {
                            throw CaptureError.aecProcessingFailed
                        }
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                mapTask.cancel()
                feedTask.cancel()
                referenceTask?.cancel()
            }
        }
    }

    private func consumeCapture(
        _ mic: AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) async {
        do {
            for try await item in mic {
                await ingestCapture(item)
            }
            if Task.isCancelled {
                // 通常停止では flush による bypass 遷移・degraded 通知を発生させない。
                await finishCapture(error: CancellationError())
            } else {
                await finishCapture(error: nil)
            }
        } catch is CancellationError {
            await finishCapture(error: CancellationError())
        } catch {
            await finishCapture(error: error)
        }
    }

    private func consumeHiddenReference(
        _ make: @Sendable () -> AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) async {
        do {
            for try await item in make() {
                await ingestRender(item)
            }
            if !Task.isCancelled {
                await noteReferenceFailed(nil)
            }
        } catch is CancellationError {
            // セッション停止による通常終了。AEC 劣化として表示しない。
        } catch {
            if !Task.isCancelled {
                await noteReferenceFailed(error)
            }
        }
    }
}
