import AppKit
import SwiftUI

/// メニューバー常駐アプリのエントリポイント(Slice 0)。
///
/// 現時点では空のメニューを出すだけの骨組み。マイク捕捉・文字起こし・ライブ議事ログ
/// UI は後続スライス(Slice 1 以降)で追加する。捕捉/文字起こしのロジックは
/// `MimizukuCore`(UI 非依存・TCC 非依存、ADR-0003)側に置く。
@main
struct MimizukuApp: App {
    var body: some Scene {
        MenuBarExtra("Mimizuku", systemImage: "waveform") {
            Button("Mimizuku を終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
