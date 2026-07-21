import AVFoundation
import CoreAudio

/// tap の IOProc が受け取る `AudioBufferList` を扱う純粋ヘルパー
/// (`TapSession` から分離。状態を持たない)。
enum TapBufferSupport {
    /// ABL 全体のサンプル数と「全サンプルが厳密に 0.0f か」を返す
    /// (ゼロサンプル watchdog 用。float32 前提)。
    static func zeroObservation(
        of inputData: UnsafePointer<AudioBufferList>
    ) -> (isAllZero: Bool, samples: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var total = 0
        var allZero = true
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            total += count
            guard allZero else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            for index in 0 ..< count where floats[index] != 0 {
                allZero = false
                break
            }
        }
        return (allZero, total)
    }

    /// ABL を `format` の新規 `AVAudioPCMBuffer` へコピーする(IO バッファと記憶域を
    /// 共有しない)。
    static func makeBuffer(
        from inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = source.first else { return nil }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else {
            return nil
        }
        buffer.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { return nil }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return buffer
    }
}
