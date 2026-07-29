import Foundation
import MimizukuCore
import Testing

@Suite("AecDriftDiagnostics")
struct AecDriftDiagnosticsTests {
    /// 0.1 秒刻み・4800 サンプルの完全一致クロックで render/capture を記録する。
    private func record(
        into diagnostics: inout AecDriftDiagnostics,
        renderRange: ClosedRange<Int>?,
        captureRange: ClosedRange<Int>?,
        captureHostStep: Double = 0.1
    ) {
        if let renderRange {
            for index in renderRange {
                diagnostics.recordRender(sampleCount: 4800, hostTime: Double(index) * 0.1)
            }
        }
        if let captureRange {
            for index in captureRange {
                diagnostics.recordCapture(
                    sampleCount: 4800,
                    hostTime: Double(index) * captureHostStep
                )
            }
        }
    }

    @Test("PPM は経過 9.999 秒では nil、10.0 秒ちょうどで値を返す(境界)")
    func tenSecondBoundary() {
        var diagnostics = AecDriftDiagnostics()
        diagnostics.recordRender(sampleCount: 4800, hostTime: 0)
        diagnostics.recordCapture(sampleCount: 4800, hostTime: 0)
        diagnostics.recordRender(sampleCount: 4800, hostTime: 9.999)
        diagnostics.recordCapture(sampleCount: 4800, hostTime: 9.999)
        #expect(diagnostics.renderPPM == nil)
        #expect(diagnostics.capturePPM == nil)
        diagnostics.recordRender(sampleCount: 4800, hostTime: 10.0)
        diagnostics.recordCapture(sampleCount: 4800, hostTime: 10.0)
        #expect(diagnostics.renderPPM != nil)
        #expect(diagnostics.capturePPM != nil)
    }

    @Test("復旧リセット後の render PPM は旧 epoch の停止時間を含まない")
    func renderResetExcludesStallTime() {
        // 12 秒の正常計測 → 30 秒の render 停止 → 復旧、を 2 系統で比較する。
        var withReset = AecDriftDiagnostics()
        var withoutReset = AecDriftDiagnostics()
        record(into: &withReset, renderRange: 0 ... 120, captureRange: nil)
        record(into: &withoutReset, renderRange: 0 ... 120, captureRange: nil)

        withReset.resetRenderForRecovery()
        // リセット直後は計測ゼロに戻る。
        #expect(withReset.renderPPM == nil)

        // 復旧後: 停止 30 秒を挟んだ t = 42.0 秒から再び完全一致クロックで記録。
        // 新 epoch の最初の record が起点になるため、10 秒(t = 52.0)までは nil。
        for index in 0 ... 99 {
            let hostTime = 42.0 + Double(index) * 0.1
            withReset.recordRender(sampleCount: 4800, hostTime: hostTime)
            withoutReset.recordRender(sampleCount: 4800, hostTime: hostTime)
        }
        #expect(withReset.renderPPM == nil)
        withReset.recordRender(sampleCount: 4800, hostTime: 52.0)
        withoutReset.recordRender(sampleCount: 4800, hostTime: 52.0)

        // リセットあり: クロックは一致しているので新 epoch の PPM はほぼ 0。
        let resetPPM = withReset.renderPPM
        #expect(resetPPM != nil)
        if let resetPPM {
            #expect(abs(resetPPM) < 1)
        }
        // リセットなし(旧実装相当): 停止 30 秒が負のドリフトとして混入する
        // (計算上 −29.9 秒 / 52 秒 ≈ −575,000 ppm)。
        let stalePPM = withoutReset.renderPPM
        #expect(stalePPM != nil)
        if let stalePPM {
            #expect(stalePPM < -500_000)
        }
    }

    @Test("capture は render 停止・復旧リセットを跨いで連続計測を維持する")
    func captureSurvivesRenderRecovery() {
        var diagnostics = AecDriftDiagnostics()
        // capture は +50ppm のクロックで、render 停止中(12〜42 秒)も記録が続く。
        let captureStep = 0.1 * (1 - 50e-6)
        record(
            into: &diagnostics,
            renderRange: 0 ... 120,
            captureRange: 0 ... 420,
            captureHostStep: captureStep
        )
        let before = diagnostics.capturePPM
        #expect(before != nil)

        diagnostics.resetRenderForRecovery()

        // リセット直後も capture の計測履歴は保持され、値が変わらない。
        let after = diagnostics.capturePPM
        #expect(after == before)
        if let after {
            #expect(after > 45 && after < 55)
        }
        // 以降の記録も連続計測として同じ傾向を保つ。
        for index in 421 ... 520 {
            diagnostics.recordCapture(sampleCount: 4800, hostTime: Double(index) * captureStep)
        }
        let continued = diagnostics.capturePPM
        #expect(continued != nil)
        if let continued {
            #expect(continued > 45 && continued < 55)
        }
    }
}
