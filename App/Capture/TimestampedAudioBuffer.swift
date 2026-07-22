import AVFoundation
import CoreAudio

/// AEC 経路用: 捕捉時刻(ホストクロック、秒)付きバッファ(ADR-0013 の 4)。
///
/// 公開契約 `AudioSource.buffers()` は変えない。マイクとシステム音声の捕捉開始時刻は
/// 大きくずれうる(#61 実測: tap 側が約 +1.2 秒遅い)ため、AEC の整列
/// (`AecAligner`)は本型のホストタイムを使う。消費者は AEC ポンプ(AEC-3)のみ。
///
/// `@unchecked Sendable` の正当化(ハード制約 #4、PR にも明記): 非 Sendable なのは
/// `buffer` のみで、これは捕捉側で独立確保されたコピーがストリームの単一消費者へ
/// 所有権ごと渡るもの(docs/domain-pitfalls.md #9 の既存運用と同一)。本型は全
/// プロパティ不変の値で、複数所有・並行変更は構造的に発生しない。
struct TimestampedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let hostTime: TimeInterval
}

enum TimestampedStreamSupport {
    /// timestamped ストリームからバッファだけを取り出す(既存の `buffers()` 契約用の
    /// アダプタ。cold・単一消費者の性質は上流に従う)。
    static func droppingTimestamps(
        _ upstream: AsyncThrowingStream<TimestampedAudioBuffer, Error>
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await item in upstream {
                        // バッファは独立コピーの単一所有(型の正当化コメント参照)。
                        // 構造体プロパティ経由では sending 性が失われるため明示する。
                        nonisolated(unsafe) let buffer = item.buffer
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `AVAudioTime`(マイク tap コールバック)からホストタイム(秒)を得る。
    /// ホストタイムが無効なら現在時刻で代用する。
    static func seconds(from when: AVAudioTime) -> TimeInterval {
        let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        return AVAudioTime.seconds(forHostTime: hostTime)
    }

    /// `AudioTimeStamp`(tap の IOProc)からホストタイム(秒)を得る。
    static func seconds(from timestamp: AudioTimeStamp) -> TimeInterval {
        let valid = timestamp.mFlags.contains(.hostTimeValid)
        let hostTime = valid ? timestamp.mHostTime : mach_absolute_time()
        return AVAudioTime.seconds(forHostTime: hostTime)
    }
}
