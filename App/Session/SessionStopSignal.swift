import Foundation

/// 利用者の停止要求を、捕捉中の複数ストリームへ1回だけbroadcastする。
///
/// セッションTask自体は直ちにcancelしない。各AudioRouterが入力を正常終了させ、SpeechEngineがfinalizeできるようにする。
struct SessionStopSignal: Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    func request() {
        continuation.yield(())
        continuation.finish()
    }
}
