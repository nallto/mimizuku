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
    /// 参照ストリームが中断した場合は新しいtapを再生成して復旧を試す。開始・復旧の
    /// 期限内に参照が得られなければ、raw micへ戻さず処理済みストリームを失敗させる。
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
        // captureやrenderの到着に依存しない期限監視。参照が完全に沈黙しても5秒で
        // 必ず処理済みストリームを失敗させる。
        let watchdogTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard await self.checkReferenceDeadline() else { return }
            }
        }
        // 隠し参照(mic-only)。中断時は期限内で再生成し、raw micへはフォールバックしない。
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
                // actorへcancel処理が届く前にwatchdogへ通常停止を可視化する。
                self.requestShutdown()
                mapTask.cancel()
                feedTask.cancel()
                referenceTask?.cancel()
                watchdogTask.cancel()
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
                // 通常停止では終了drainによる状態遷移・失敗通知を発生させない。
                await finishCapture(error: CancellationError())
            } else {
                // ライブマイクは利用者停止まで継続する契約。非キャンセルの正常終了は
                // flush対象ではなく予期しない入力喪失として扱う。
                await finishCapture(error: CaptureError.sourceEndedUnexpectedly(.microphone))
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
        while !Task.isCancelled, shouldRetryReference() {
            do {
                for try await item in make() {
                    await ingestRender(item)
                }
                if !Task.isCancelled {
                    await noteReferenceInterrupted(nil)
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    await noteReferenceInterrupted(error)
                }
            }

            guard !Task.isCancelled, shouldRetryReference() else { return }
            // process tap の create→destroy→create を即時連打しない。ソース内部の再構築で
            // 回復できずストリームが終了した場合だけ、短いbackoff後に新規tapを作る。
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }
}
