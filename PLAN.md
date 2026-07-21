# S4 作業状態(feat/37-dual-stream。マージ前に削除)

計画は Issue #37 / 会話で承認済み。ラベル表記はライブログ「自分 / 相手」、設定・診断は「マイク / システム音声」。

## 残ステップ

- [x] Core: `CaptureSelection`(マイク/システム/両方 → streams)+ テスト
- [x] Core: `SessionRetention.shouldDiscard(durations:minimumDuration:)`(最長 duration < 2s で破棄)+ テスト
- [x] App: `AudioRouter.route` に `onFirstBuffer` コールバック追加(時刻同期計測用)
- [x] App: `AudioSessionController` 複数ストリーム化(TaskGroup、engine をストリーム毎、prepare 直列、マイク TCC 事前確認 = T5 修正、最長 duration 破棄、両ファイル AAC 変換、初回バッファ offset ログ)
- [x] App: `App/Diagnostics/` 新設(マイク権限プローブ、システム音声 tap 生成プローブ、診断モデル)
- [x] App/UI: `DiagnosticsView`(権限診断ウィンドウ、3 行 + 修正アクション)
- [x] App: `MimizukuApp` — Picker 3 択化、権限診断メニュー + ウィンドウ追加
- [x] App/UI: `LiveLogView` — 確定行・volatile 行に「自分 / 相手」ラベル
- [x] `local/s4-test-script.md`(手動テスト台本)
- [x] `just check` green(37 テスト)+ `just app-build` 成功
- [ ] verifier(/verify)
- [ ] コミット前に停止して報告(Approval-driven)→ ユーザー手動テスト(台本)

## 判明した事実・決め事

- **AEC(VPIO)は撤退**(ユーザー決定)。ダッキングで tap 捕捉が約 20dB 減衰し「両方」のシステム文字起こしが死ぬ + 入力 5ch 化。domain-pitfalls #12 に記録、将来対策は Issue #59。スピーカー運用のエコーはヘッドホンで回避。

- ラベル: ライブログは「自分(マイク)/ 相手(システム音声)」。ユーザー指定。
- システム音声の TCC は公開照会 API 無し → tap 生成試行をプローブとし、断定表現を避ける。
- 時刻同期は計測のみ(初回バッファ到着の差分を notice ログ)。厳密整列は D2/S7 送り(Issue #37 にメモを残す)。
- 診断の deep link: マイク = Privacy_Microphone。システム音声 = Privacy_AudioCapture(実在は手動テストで確認、外れたら Privacy ルートに落ちる想定)。
