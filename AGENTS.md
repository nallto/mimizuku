# プロジェクト規約(Mimizuku)

このリポジトリで作業するすべての人間と AI エージェントが従う規約の正典(Single Source of Truth)。AGENTS.md を直接読まないツール(Claude Code)は`CLAUDE.md` の import 経由で本ファイルを読み込む。

> 原則: **機械が強制できることはここに書かない。** 強制は linter / hooks / CI / ブランチ保護が担う(`scripts/agent-hooks/`・各Agentの接続設定・`.github/workflows/`・リポジトリ設定が正)。ここには非自明なルールと理由だけを書く。

## プロジェクト概要

Mimizuku は、録音・オンデバイス文字起こし・ノートを統合した macOS のメニューバー常駐アプリ(ADR-0005)。マイクとシステム音声(いずれか、または両方)を録音・保存し、Apple の Speech フレームワーク(`SpeechAnalyzer` / `SpeechTranscriber`)で完全オンデバイスのリアルタイム文字起こしを行う。対応言語は日本語と英語を最低限とする。UI はライブ議事ログに加え、3 ペインのメインウィンドウ(セッション一覧 / 波形付き再生 + 文字起こし / 要約・TODO・メモ)を持つ。翻訳・要約は Apple のオンデバイスフレームワーク(Translation / FoundationModels)で開始し、ローカル/クラウド LLM へ差し替え可能な抽象を設計する(クラウド利用の条件は ADR-0010 予定で決定するまで導入しない)。アプリ内辞書・横断検索・再文字起こし・動画/音声インポートをロードマップに含む(`docs/plan/IMPLEMENTATION_PLAN.md`)。OSS として公開し、App Store 外(Developer ID + notarization)で配布する。

- スタック: Swift 6(strict concurrency)、SwiftUI `MenuBarExtra` App ターゲット +ローカル SPM パッケージ 1 つ(`MimizukuCore`)。捕捉は `AVAudioEngine`(マイク)と Core Audio process tap(システム音声)。保存はオンデバイスのみ(XDG Base Directory 準拠 ―― データは `$XDG_DATA_HOME`、既定 `~/.local/share/mimizuku/` 配下。ADR-0006)。
- 最小ターゲット: macOS 26.0、Apple Silicon 限定(ADR-0001)。

## 言語

- ユーザーとの会話: 日本語。
- **リポジトリにコミットする文書(規約・docs・ADR・コメント)は、開発中は日本語**で書く。README の英語版整備は公開前タスク(TODO(defer))。
- **PR タイトル**は Conventional Commits に従う。type は英語トークン(`feat` `fix` 等)、要約(summary)は日本語でよい。コード識別子は英語。
- 秘密情報・鍵・トークンはコミットしない。

## Markdownの改行

- 通常の文章は**1段落を1物理行**で書き、表示幅による折り返しはエディタのソフトラップに任せる。読みやすさのためだけに段落途中へ改行を入れない。
- 段落、リスト、表、コードブロック、意図的なMarkdown hard breakなど、意味を持つ改行は保持する。判断理由と対象範囲はG-0007。
- プロジェクト所有のMarkdownはPrettierで整形する。手作業で改行を直し続けず、`just fmt`で修正し`just check`で検査する。

## ハード制約(絶対に破らない。変更提案の前に必ず ADR を起票する)

1. **本リポジトリのどこにも private API を使わない。** App Store 適格性と OS 更新時の安定性を守るため、非公開 API に依存しない。
2. **音声と文字起こしはデバイス外に出さない。** 音声・文字起こしデータを運ぶネットワーク通信を行わない。既定でテレメトリを持たない。
3. **最小デプロイターゲット: macOS 26.0、Apple Silicon 限定**(ADR-0001)。
4. **Swift 6 言語モード、strict concurrency。** コード内コメントでの正当化理由とPR での言及なしに `@unchecked Sendable` を使わない。
5. **`Packages/*` は UI 非依存・TCC 非依存に保つ。** 権限や AppKit を要するものはApp ターゲットか、プロトコルの裏に置く。

既に他者の時間を奪った実績のあるドメイン上の罠(Core Audio taps・Speech・CI)は[`docs/domain-pitfalls.md`](./docs/domain-pitfalls.md) に集約。捕捉・文字起こしのコードに触れる前に必ず読む(再発見しない)。

## 検証(最重要ルール)

- 完了報告の前に必ず `just check` を実行し、green を確認する。`just check` は CI と同一内容。これが green でない作業は「完了」ではない。タスク一覧は `just --list`。
- `just check` は純ロジックのパッケージテストのみを実行する。**TCC 権限や実音声ハードウェア(マイク・システム音声 tap)を要するものは CI で実行できず、人間がローカルで検証する**(domain-pitfalls #8)。
- 非自明な変更はverifierサブエージェントの第三者検証も通す。自分の仕事を自分だけで採点しない(手順: `.agents/skills/verify/SKILL.md`)。

## 作業の始め方(Issue 起点)

- 実装・調査・修正は、対応する **GitHub Issue から始める**。無ければ着手前に起票する(流動的タスクの正典は Issue ―― 「知識の置き場所」参照)。会話の文脈や AI の auto-memory でタスクを管理しない(チームに共有されず失われるため)。
- Issue に着手する前に、担当者(assignee)が未設定なら**自分をアサイン**する(チーム開発での二重着手を防ぐ。Claude Code では `gh issue edit <番号> --add-assignee @me`)。
- ブランチは Issue 番号で切る: `<type>/<issue番号>-<短い説明>`。**1 Issue = 1 PR**(下記「ブランチとマージ」)。
- 実装計画のスライスは、[`docs/plan/IMPLEMENTATION_PLAN.md`](./docs/plan/IMPLEMENTATION_PLAN.md) の各スライス = 1 Issue として**事前に起票**しておく(着手時に Issue 番号でブランチを切れる状態にする)。
- 例外: リポジトリ setup や軽微な雑務など Issue 化の価値が薄いものは Issue 無しでよいが、その理由を PR 概要に書く。

## ブランチとマージ(理由と例外条件: G-0001)

- trunk-based development。変更は 短命ブランチ → PR → CI green → **squash merge** のみ。merge commit / rebase merge はリポジトリ設定で無効化する。
- コミットからpush、PR、CI監視、マージ前承認、squash merge、main同期、ブランチ削除、stacked branchの載せ直しまでの**環境非依存の具体手順**は [`docs/development.md`の「変更をmainへ統合する」](./docs/development.md#変更を-main-へ統合する) を正典とする。Claude Code固有スキルや会話履歴だけを手順の置き場所にしない。
- PR タイトルは Conventional Commits 1.0.0 準拠(CI が検証)。ブランチ上の個々のコミット形式は自由。
- ブランチ名: `<type>/<issue番号>-<短い説明>`(例: `feat/12-mic-source`)。
- 1 Issue = 1 PR。PR は小さく保ち、マージ後のブランチは削除する。
- 1 PR = 実装 1 スライス。スライス順は[`docs/plan/IMPLEMENTATION_PLAN.md`](./docs/plan/IMPLEMENTATION_PLAN.md) に従い、勝手に並べ替えない。大きな変更の分割は G-0003。

## リリース(理由と release ブランチ導入条件: G-0002)

- main は常にリリース可能に保つ。リリースは release-please のリリース PR をマージしたときにのみ発生する(タグ + GitHub Release + CHANGELOG)。常設のrelease / 環境ブランチは持たない。
- 配布は Developer ID 署名 → notarize → staple → Homebrew cask。署名・notarizationの workflow はリリーススライス(Slice 4)で追加する。
- TCC プロンプトは正しく署名されたビルドでのみ出る。未署名成果物を配布しない(domain-pitfalls #4)。

## テスト方針

- テストフレームワークは Swift Testing(`import Testing`)。パッケージテストは各パッケージの `Tests/` に置く。
- モデル・エンコード・ルーティング・watchdog ロジックは CI で検証可能。アサーションのないテストや実装をなぞるだけのテストは書かない。
- 中核ロジックの変更には境界値・異常系のテストを必ず伴わせる。
- TCC / ハードウェア依存のテストはローカル限定。CI 経路から外す。

## 知識の置き場所

AI のメモリ(auto memory / `CLAUDE.local.md`)は個人ローカルであり、チームに共有されない。「他の人(やその AI)も知るべき」と思った瞬間に Git 管理ファイルへ書く。

| 知識の種類 | 置き場所 |
| --- | --- |
| 個人の揮発メモ・個人設定 | `CLAUDE.local.md` / auto memory(コミットしない) |
| チームの人間・AI 向け規約 | 本ファイル |
| UI/UXの原則・視覚言語 | `docs/DESIGN.md`、画面・操作仕様は`docs/design/` |
| 設計判断の理由 | `docs/adr/`(製品)/ `docs/adr/governance/`(プロセス) |
| ドメインの罠・落とし穴 | `docs/domain-pitfalls.md` |
| 流動的なタスク・調査ログ | GitHub Issues |
| 恒久的な仕様(利用者向け) | `README.md` |
| 恒久的な仕様(開発・設計向け) | `docs/` |

- 不変条件: **docs・コード・テストは同じ PR で一致させる**(乖離を後追いにしない)。
- 設計判断は実装の前(または同じ PR)で ADR に残す。手順: `.agents/skills/adr/SKILL.md`。

## Agent共通ワークフロー

- 正式に接続しているAgent、skill探索方式、hook接続先は `.agents/integrations.json`を機械可読な一覧とする。未登録のAgentは `AGENTS.md`を入口に`.agents/skills/`を直接読むfallbackとして扱う。
- Agentがこのリポジトリ用に明示的に作るworktreeは`local/worktrees/`、セッションやコマンドを越えて参照するプロジェクト固有の作業ファイルは`local/`に置く。`.claude/`と`.codex/`、システム一時領域を共通作業物の正式な置き場所にしない。終了時に必ず削除するfixtureとOS・toolchain・Agent製品自身の内部データは例外とする。具体的な作成方法と境界は[`docs/development.md`の「Agent worktreeと作業ファイル」](./docs/development.md#agent-worktreeと作業ファイル)、理由はG-0009に従う。
- Agent向けskill本文の正典は`.agents/skills/`に置く。ここを直接探索しないAgentも、作業開始時に本ファイルから対応する`SKILL.md`を読んで適用する。
- `.claude/skills/`はClaude Codeの探索用アダプターであり、共通skillを参照するだけにする。手順本文を複製しない。skill自体が`/adr`、`/check`、`/verify`等の起動口になるため、同名の`.claude/commands/`は持たない。
- `.claude/agents/`など、各製品固有のサブエージェント定義には役割と共通基準への参照だけを置く。検証基準の正典は`.agents/skills/verify/references/`に置く。
- Agent間で共有できる決定的なhook実装は`scripts/agent-hooks/`に置く。 `.claude/settings.json`や`.codex/hooks.json`はイベントを共通実装へ接続するアダプターとする。イベント形式が異なるhookと権限設定は製品別に管理する。
- `.claude/settings.local.json`などのローカル設定は共通規約・手順の置き場所にせず、コミットしない。
- `.agents/`、`.claude/`、`.codex/`、`scripts/agent-hooks/`、またはAgentの動作を変える規約・設定へ触れる作業は、着手前に `.agents/skills/agent-config/SKILL.md`を読む。registryにある全Agentとfallbackの影響表を計画へ含め、影響なしの場合も理由を書く。
- 新しいAgent製品を正式対応するときは`.agents/integrations.json`へ登録し、既存の全共通skill、hook、検証手順への到達方法を同じ変更で追加する。

## コミットと PR

- squash 後に main に残るのは「PR タイトル + squash 本文」。squash 本文は **PR 本文全文**(#14 スタイル)なので、PR 説明(概要 / 変更内容 / 関連 Issue / Squash body / チェックリスト)がそのまま履歴に残る。レビューコメント・ブランチ上のコミット列は残らない前提で扱う。
- コミットしない: 署名証明書・プロビジョニング成果物・`.env`・録音音声・文字起こし。ツールを問わない統合手順は上記`docs/development.md`を直接読む。commit-and-prスキルは同じ正典へ入る入口とし、別手順を定義しない。

## AI エージェントの作業規律

- 非自明な変更は、着手前に計画(対象・手順・検証方法・トレードオフ)を提示し、承認を得てから実行する。手順: `.agents/skills/plan-execute-verify/SKILL.md`。
- 計画の承認後は合意した範囲を進め、変更確認と検証結果を示してからコミットする。計画からの逸脱、PRマージ、ブランチ削除、外部公開などの不可逆・外向き操作は、直前に対象と状態を示して明示承認を得る。
- 利用者が完了条件、時間、試行回数などの上限を指定した場合はタスクの停止条件として扱う。指定の有無によって上記の計画・検証・承認手順を切り替えない。
- UI(`App/UI/`配下や新規ビュー)に触れる作業は、着手前に `.agents/skills/macos-ui-design/SKILL.md`を入口として`docs/DESIGN.md`と対象の`docs/design/`画面・操作仕様を読む。未登録Agentも`AGENTS.md`→共通skill→デザイン正典の同じ経路を使う。
- コード変更や既存設計について、呼び出し経路・状態フロー・責務境界・HTMLによる詳細な可視化説明を求められた場合は、`.agents/skills/explain-code/SKILL.md`を読む。通常の変更報告には自動適用しない。
- 規約・設定・docs に改善余地を見つけたら、勝手に変えず提案する。
- 秘密情報(`.env`・鍵・トークン)は読まない・書かない・コミットしない(permissions / hooks / CI gitleaks でも強制されるが、規律としても守る)。
