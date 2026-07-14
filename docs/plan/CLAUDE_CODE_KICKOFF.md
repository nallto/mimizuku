# Claude Code kickoff

リポジトリ直下で開始した Claude Code セッションの最初のメッセージとして、以下を(適宜調整して)貼り付ける。まず plan mode で実行する。

---

何かを始める前に、`AGENTS.md`、`docs/domain-pitfalls.md`、`docs/adr/0001..0003`、`docs/adr/governance/G-0001..G-0004`、`docs/plan/IMPLEMENTATION_PLAN.md` を読むこと。

その後、実装計画の **Slice 0** を実行する:

1. パッケージがビルドでき、プレースホルダテストが通ることを確認: `swift test --package-path Packages/MimizukuCore`(= `just test`)。stub レベルのコンパイルエラーがあれば直す(`AudioSource.swift` / `TranscriptionEngine.swift` の契約が正典。契約自体が誤っていそうなら、変更せず止まって質問する)。
2. Slice 0 task 2 のとおり Xcode App プロジェクトを作成(MenuBarExtra、LSUIElement、デプロイターゲット 26.0、Swift 6 strict concurrency)。`Packages/MimizukuCore` を依存として追加し、Info.plist の 3 つの usage string を追加 ―― `NSAudioCaptureUsageDescription` は手入力が必要。
3. `.github/workflows/ci.yml` に App ビルドジョブを追加する。
4. 何かをコミットする前に、完全な diff と Slice 1 の計画を私に見せる。

制約の再確認: private API を使わない。音声に触れるネットワーク通信をしない。パッケージコードはUI 非依存に保つ。不可逆な操作の前に必ず確認する。検証は `just check`(機械)+ verifier (第三者)の 2 段。

---

## 以降のスライスのセッション衛生

- 1 スライス = 1 セッション/ブランチ。各セッションはそのスライスの受け入れ条件の再読から始める。
- Core Audio 作業(Slice 2): 先に `docs/domain-pitfalls.md` を再読する。ハッピーパスを磨く前にwatchdog を実装する。
- 受け入れ条件が手動の音声テスト(soak run、デバイス切替)を含む場合、Claude Code は計測用の仕掛け(ログ・診断画面)を用意し、物理テストは人間が行う。
