import Foundation

/// オンデバイス音声認識モデル(ロケール別アセット)の導入状態。UI 表示用の純粋な状態型。
///
/// アセットはロケールごとに数百 MB で、初回利用前に一度だけダウンロードが要る
/// (docs/domain-pitfalls.md #5)。ダウンロードは Apple のモデルファイルのみを運び、
/// 音声・文字起こしは一切載せない ―― ハード制約 #2(音声/文字起こしをデバイス外に
/// 出さない)には抵触しない、本アプリで唯一の外向き通信。
///
/// 進捗率は持たない(初回の一度きりのため)。ダウンロード / 準備中は UI 側で
/// 不確定アニメーション(スピナー)を回して「動いている」ことだけを示す。
public enum ModelAssetStatus: Sendable, Equatable {
    /// アセット未導入(ダウンロードが必要)。
    case notInstalled
    /// ダウンロード / 準備中(UI は不確定スピナーを表示)。
    case downloading
    /// 利用可能(文字起こし開始可)。
    case ready
    /// 導入に失敗(理由を UI に提示)。
    case failed(reason: String)
}
