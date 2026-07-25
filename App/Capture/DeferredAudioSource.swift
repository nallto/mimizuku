import AVFoundation
import MimizukuCore

/// ストリーム生成を `buffers()` 呼び出し時(= AudioRouter のルーター Task 内、
/// off-main)まで遅延する薄いラッパー。
///
/// `AsyncThrowingStream` の build クロージャは**生成時に同期実行**されるため、
/// @MainActor の配線コード(`AudioSessionController.makeInputs`)でソースの
/// ストリームを即時生成すると、HAL 同期照会・`AVAudioEngine.start()` が main thread に
/// 載ってしまう(docs/domain-pitfalls.md #10 ―― S2 で実クラッシュした条件)。
/// 本型で包むことで、評価タイミングと解放連鎖を従来の cold ソースと一致させる。
struct DeferredAudioSource: AudioSource {
    let kind: StreamKind
    let make: @Sendable () -> AsyncThrowingStream<AVAudioPCMBuffer, Error>

    func buffers() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        make()
    }
}
