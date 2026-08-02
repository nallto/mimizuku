---
name: macos-ui-design
description: macOSネイティブSwiftUIのUI/UX実装手順。App/UI配下の変更、新規ビュー、アニメーション、レイアウトの作業前に正典と対象画面仕様を確認するときに使う。
---

# macOS UI実装手順(SwiftUI)

UI/UXの原則と視覚言語は[`docs/DESIGN.md`](../../../docs/DESIGN.md)を正典とする。このskillへ原則本文を複製しない。

## 着手前

1. [`docs/DESIGN.md`](../../../docs/DESIGN.md)を完全に読む。
2. 対象画面の仕様を読む。メインウィンドウは[`docs/design/main-window.md`](../../../docs/design/main-window.md)、共通状態と操作は[`docs/design/interaction-patterns.md`](../../../docs/design/interaction-patterns.md)を使う。
3. 対象スライスとADRの導入境界を確認する。未決定の技術選択や将来スライスを先行実装しない。
4. `NavigationSplitView`、`.inspector`、`Menu`、`Table`、`.searchable`など標準コンポーネントで表現できるか確認する。自作が必要なら標準で満たせない要件と理由を計画とPRへ記録する。
5. 変更する状態ごとに、表示、可能な操作、キーボードフォーカス、VoiceOver、エラー、空状態を列挙する。

## 実装中

- 入力へ即時フィードバックを返し、時間のかかる処理は具体的な処理名と進捗を表示する。
- ドラッグやスクラブはポインタへ直接追従させ、標準のキーボード代替操作を用意する。
- アニメーションが必要な場合は割り込み可能な`withAnimation`を使い、基本は`.spring(duration: 0.3...0.4, bounce: 0)`とする。運動量を引き継ぐ直接操作だけ`bounce: 0.2`まで許容する。
- `@Environment(\.accessibilityReduceMotion)`を確認し、Reduce Motionではスライドやspringを短いクロスフェードまたは即時更新へ置き換える。
- システムアクセント、セマンティック色・書体、SF Symbols、標準Materialを使う。固定カラーパレット、独自フォント、独自の半透明レイヤを追加する場合は正典の拡張が先に必要である。
- macOSはDynamic Type非対応である。「Dynamic Type対応」を完了条件にせず、セマンティックなシステム書体、文字を切らない可変レイアウト、必要箇所の表示倍率・文字サイズ調整可能性を確認する。
- ツールバー、コンテキストメニュー、標準メニューの同名操作は同じCommandと有効条件を共有する。

## PR前チェックリスト

- [ ] 標準コンポーネントで表現できないか検討したか(自作した場合、理由を PR に書いたか)
- [ ] `docs/DESIGN.md`、対象画面仕様、対象スライス、ADRの境界と一致するか
- [ ] recording、completed、interrupted、recoveryNeeded、読み込み失敗、空状態など変更対象の全状態を確認したか
- [ ] 時間のかかる処理に即時フィードバック、具体的な処理名、適切な進捗があるか
- [ ] キーボードだけで主要操作へ到達でき、テキスト入力とショートカットが競合しないか
- [ ] VoiceOverの名前、値、グループ、動的通知が適切か
- [ ] Reduce Motion、Increase Contrast、Reduce Transparencyで情報が失われないか
- [ ] ライト／ダーク両方で本文、選択、disabled、警告、フォーカスが識別できるか
- [ ] 自動化できない確認結果または未確認理由をPRへ記録したか
