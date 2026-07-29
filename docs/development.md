# 開発ガイド

開発者向けのセットアップと、このリポジトリの「強制装置」の全体像(利用者向け情報は README)。

## セットアップ

前提は [mise](https://mise.jdx.dev/) と **Xcode 26**(App Store / Apple Developer より)。補助ツールの版数は `mise.toml` が SSOT。Swift コンパイラは Xcode 由来。

```bash
mise install    # just / jq / swiftlint / swiftformat / node / prettier
just --list     # 利用可能なタスク
just check      # CI と同一の検証
```

## 検証の原則

- **`just check` = CI。** ローカルで green なら CI も green(乖離したらバグとして直す)。CI はデプロイターゲット(ADR-0001)に合わせ `macos-26`(Apple Silicon)で実行する。
- `just check` = `setup-check` + `agent-config-check` + `lint`(swiftlint) + `fmt-check`(swiftformat / Prettier) + `test` (MimizukuCore の swift test)。
- **`just check` は純ロジックのみを検証する。** マイク / システム音声 / TCC / モデルアセットの挙動はホスト型ランナーで実行できない(domain-pitfalls #8)。それらは各スライスに記した手動テストで人間がローカル検証する。

## Markdownの整形

通常の文章は1段落を1物理行とし、表示上の折り返しはエディタのソフトラップに任せる(G-0007)。Prettierの`proseWrap: never`と版数は`.prettierrc.json`と`mise.toml`で固定する。`just fmt`はSwiftとプロジェクト所有のMarkdownを整形し、`just check`は未整形のMarkdownを検出する。

対象はgit管理済み、またはgitignoreされていない未追跡のMarkdownである。release-please生成物の`CHANGELOG.md`、外部由来の`third_party/`、gitignoreされた個人ローカル文書は除外する。Claude Codeは既存のPostToolUse hookからMarkdownを自動整形し、Codexと未知のAgentは`just fmt`と`just check`を使う。

## ログレベルの方針(os.Logger)

unified logging の実仕様に基づく使い分け。**`Logger.warning()` は使わない** ―― macOS の統一ログに Warning という独立種別は無く、`warning()` は **Error 種別として記録される**(想定内イベントが Console 上で Error に見える罠。S3 実装時に発覚)。

| レベル | 永続化 | 使いどころ | 例 |
| --- | --- | --- | --- |
| `error` | される | **本物の失敗のみ** | セッション失敗、AAC 変換失敗、再構築試行の失敗 |
| `notice`(既定) | される | 事後診断に必要な重要イベント | capture started/stopped、watchdog 再構築、モデルダウンロード、データ破棄(短セッション)、クラッシュ回復 |
| `info` | されない(メモリのみ) | ライブ観察時だけ意味がある詳細 | (現状使用なし) |
| `debug` | されない | 開発時のみ | — |

判断基準:

- 「無音なだけでも起こりうる」ような**想定内イベントを error にしない**(利用者・開発者がログを見たとき本物の障害と区別できなくなる)。
- **ユーザーデータに触る決定(破棄・変換・回復)は必ず永続ログ(notice 以上)に痕跡を残す**(「録音が消えた」の事後調査に備える)。
- 事後診断で時系列を再構成するイベント群(セッション開始/停止と再構築など)は、**同じ永続レベルに揃える**(片方だけ info だと繋がらない)。

## WebRTC APM(AEC3)のベンダリング

エコーキャンセル(ADR-0013)は WebRTC の audio_processing を静的リンクで使う。

- `just vendor-apm`(`just app-build` が自動実行)が freedesktop 版 webrtc-audio-processing を**ピン留めコミット**から取得し、meson + ninja(mise 管理)で arm64 静的ライブラリを `Vendor/webrtc-apm/` に生成する。abseil は meson の wrap で自己完結ビルドし、全静的ライブラリを `libwebrtc-apm-bundle.a` 1 本に束ねる。
- **成果物(`Vendor/`)はコミットしない**(gitignore)。ピンの更新は `scripts/build-webrtc-apm.sh` の `PINNED_COMMIT` を変更する(CI キャッシュのキーもこのファイルのハッシュ)。
- Swift から C++ は直接触らない。`App/Audio/AudioProcessingBridge.{h,mm}`(Obj-C++)が境界(ADR-0013)。
- 帰属表示(BSD-3-Clause + PATENTS)は `third_party/webrtc-audio-processing/` に同梱。
- オフライン検証 CLI: `aecprobe <mic> <system> <out.wav>`(スキーム `aecprobe`)。実録音ペアを APM に通し、処理後 WAV と far-end 有音窓の平均抑圧量(dB)を出力する。

## コンテナ / devcontainer を使わない理由

核となる作業は macOS ネイティブのフレームワーク(Speech、Core Audio、TCC、AppKit)を要する。これらは Linux コンテナの中ではビルドも検証もできないため、devcontainer は置かない。再現性は mise(ツール版数)+ ピン留めした `macos-26` ランナー・Xcode で担保し、コンテナには頼らない。

## 開発環境の分離(作業用 PC を汚さない)

「ツール類を作業用 PC に直接入れず、隔離した環境に入れたい」という方針への対応。3 段階で考える。

- **CLI ツール(just / jq / swiftlint / swiftformat / Node.js / Prettier)**: mise がプロジェクト単位で隔離する。インストール先は mise 管理下(`~/.local/share/mise` 等)で、Homebrew のようなグローバル汚染をせず、`mise.toml` で版数もプロジェクトに固定される。複数プロジェクトの併存もこれで分離できる。**この層は現状すでに隔離されている。**
- **Xcode / macOS SDK / 実アプリのビルド・実行**: **コンテナ化できない**(macOS はコンテナ化不可)。作業用 PC の外に出したいなら、選択肢は **macOS 仮想マシン**(Apple の Virtualization.framework をベースにした [Tart](https://tart.run/)、UTM 等)。別の macOS インスタンスに Xcode + ツールを入れれば、ホストの作業用 PC を汚さずに丸ごと隔離できる。ただし VM は 1 つ数十 GB と重く、初期構築コストがかかる。
- **TCC・実音声ハードウェアの最終検証**: VM では音声デバイスのパススルーや TCC 挙動に制約が出ることがあり、システム音声 tap の最終確認は実機 Mac が確実。

まとめると、**CLI ツールは mise で既に隔離済み。ツールチェーン全体(Xcode 含む)まで隔離したいなら macOS VM(Tart 等)を使う。ただし音声の最終検証は実機で行う。** どの粒度で隔離するかは運用コストとのトレードオフで選ぶ。

## ドキュメントの公開(GitHub Pages)

`docs/` は MkDocs Material で静的サイト化し、GitHub Pages に公開する(`.github/workflows/docs.yml`)。

- 初回のみ: リポジトリ設定 → Pages → Source を「GitHub Actions」にする。
- 公開は main への push で自動(`docs/` または `mkdocs.yml` を変更したとき)。
- ローカルプレビュー: `pip install mkdocs-material && mkdocs serve`。mkdocs は docs 専用ツールで、mise 管理下の Swift ツールチェーンには含めない。
- 注意: サイトの対象は `docs/` 配下。リポジトリ直下の `README.md` / `AGENTS.md` へのリンクはサイト上では解決されない(GitHub のリポジトリ表示では有効)。

## 強制装置の一覧(どの層が何を守るか)

| 層 | 装置 | 守るもの |
| --- | --- | --- |
| リポジトリ設定 | ブランチ保護 / squash のみ | main の不変条件(G-0001) |
| CI | ci / pr-title / security | 検証・コミット規約・シークレット混入 |
| Claude Code | `.claude/settings.json` permissions | 秘密情報の読取・force push の拒否 |
| Claude Code / Codex | `scripts/agent-hooks/protect-command.sh`(PreToolUse) | 危険コマンドのブロック(2層目) |
| Claude Code | `.claude/hooks/post-edit.sh`(PostToolUse) | 編集ごとの自動整形(swiftformat / Prettier) |
| 規約文書 | AGENTS.md | 機械強制できない非自明ルールのみ |

規約文書は最弱の層。新しいルールを作るときは、まず上の層で強制できないかを検討する。

## Agent向けファイルの配置

手順や判断基準の多重管理を避けながら、Claude Code、Codex、その他のAgentから同じ内容へ到達できるよう、次の責務に分ける。

| 配置 | 責務 | 管理方針 |
| --- | --- | --- |
| `AGENTS.md` | 全員が常時知る規約と正典への索引 | Single Source of Truth |
| `.agents/integrations.json` | 正式対応Agent、skill探索方式、hook接続先 | 機械可読な対応一覧 |
| `.agents/skills/` | 再利用する手順本文、検証基準、参照資料 | Agent共通の正典 |
| `.claude/skills/` | Claude Codeのskill探索から共通skillへ接続 | 手順を持たない薄いアダプター |
| `.claude/agents/` | Claude Code固有のサブエージェント定義 | 役割と共通基準への参照だけ |
| `scripts/agent-hooks/` | Agent間で共用できる決定的なhook処理 | 実装の正典 |
| `.claude/settings.json` | Claude Codeの権限とhook接続 | Claude Code固有 |
| `.codex/hooks.json` | Codexのhook接続 | Codex固有 |
| `.claude/hooks/post-edit.sh` | Claude Codeの編集イベントから単一ファイルを整形 | イベント形式が異なるため固有 |

Claude Codeは`.claude/skills/`、Codexは`.agents/skills/`をプロジェクトskillの探索場所とするため、探索用ファイル自体は分かれる。ただし`.claude/skills/`には対応する共通`SKILL.md`を読む指示だけを置き、手順本文は複製しない。

commandsはskillと機能が重複し、Claude Codeでは同名skillが優先されるため、 `.claude/commands/`に`adr`、`check`、`verify`を重ねて持たない。slash commandは対応するClaude Code skillから提供する。

PreToolUseのshell入力は両製品とも`tool_input.command`として受け取れるため、危険コマンド判定を共通化する。PostToolUseは、Claude CodeのEdit/Writeが単一の `file_path`を渡すのに対し、Codexの`apply_patch`は複数ファイルを扱いうるため、自動整形hookを無理に共通化しない。Codexでは最終的な`just check`を整形保証とする。

`.codex/hooks.json`はプロジェクト設定として信頼された環境で有効になる。Agentのsandboxや権限モデルは製品ごとに異なるため完全には共通化せず、禁止理由を `AGENTS.md`、共用できる判定を`scripts/agent-hooks/`、接続と追加権限を製品別設定に分離する。個人用の`.claude/settings.local.json`はGit管理しない。

### Agent設定を変更するとき

`.agents/`、`.claude/`、`.codex/`、`scripts/agent-hooks/`などに触れる前に `.agents/skills/agent-config/SKILL.md`を読み、`.agents/integrations.json`に登録された全Agentとfallbackについて影響表を作る。

共通skillを追加すると、`just agent-config-check`はregistryで`adapter`方式に登録された全Agentへ同名アダプターがあることを要求する。逆に、共通skillのない孤立アダプターも拒否する。frontmatterはRuby標準のPsychでYAMLとして解析し、文字列の`name`と`description`を要求する。Rubyは最小対応環境のmacOS 26とCI runnerに含まれる`/usr/bin/ruby`を使い、追加のgemは必要としない。Rubyを使わない場合はYAML parserの自作ではなく、再現可能なparserを`mise.toml`へ追加して置き換える。

adapterは探索と製品固有設定だけを持つ薄い入口なので24行を上限とする。超える場合は共通skillや参照資料へ移せる手順本文が混入していないか確認する。共通skillと同名のClaude Code commandは、個別の名前一覧ではなく全共通skillを基準に拒否する。

成功中の現構成だけでは、adapter欠落時などの失敗分岐にあるshell互換性問題を検出できない。構成検査ではRuby欠落を模擬し、一時fixtureへadapter欠落、同名command、不正YAML、adapter肥大をそれぞれ作り、意図した診断でfailすることも確認する。

新しいAgent製品へ正式対応する場合は、registryへ次を登録する。

- `id`: 製品を識別する安定した名前
- `skills.mode`: 共通skillを直接探索する`native`、製品別入口を置く`adapter`、指示ファイルから読む`instructions`
- `skills.path`: 探索または入口に使うパス
- `hooks`: 共通hookへ接続する製品別設定ファイル

registryにない未知のAgentは`AGENTS.md`から`.agents/skills/`を読むfallbackで作業できるが、製品固有のskill自動探索やhook動作までは保証しない。正式対応へ昇格するときにregistry、接続層、既存全skillへの到達方法、手動確認結果を同じPRへ追加する。

CIで確認できるのはファイル構造、YAML、参照、hook判定までである。製品上のskill列挙、project trust、hook発火は、新規sessionで手動確認しPR本文へ結果または未確認理由を残す。

## Agent worktreeと作業ファイル

Agentや開発者がこのリポジトリ用に明示的に作るGit worktreeは`local/worktrees/<issue番号>-<短い説明>/`へ置く。ブランチ名は従来どおり`<type>/<issue番号>-<短い説明>`とし、mainを同期してから次のように作成する(G-0009)。

```bash
git worktree add \
  local/worktrees/88-agent-workspace \
  -b chore/88-agent-workspace \
  main
```

終了後は「変更をmainへ統合する」の承認と後始末に従って`git worktree remove`する。稼働中のworktreeを配置規約の変更だけを理由に移動・削除せず、次に作るworktreeから適用する。

製品がセッション開始前にworktreeを作る場合は、その時点では`AGENTS.md`をまだ読めないため、リポジトリ規約だけで保存先を強制できない。利用形態ごとの接続方法は次のとおり。

| 利用形態 | 接続方法 |
| --- | --- |
| [Codex App](https://learn.chatgpt.com/docs/environments/git-worktrees) | Settings > Worktrees > Worktree rootで、このリポジトリ用の保存先を指定できる場合は`local/worktrees/`へ向ける。Codexが管理するworktreeの保存先はリポジトリ設定から強制しない。 |
| Codex CLI・未登録Agent | 上記の`git worktree add`で作成し、そのディレクトリからAgentを起動する。 |
| [Claude Desktop](https://code.claude.com/docs/en/desktop) | Settings > Claude Code > Worktree locationで、このリポジトリ用の保存先を指定できる場合は`local/worktrees/`へ向ける。 |
| [Claude Code CLI](https://code.claude.com/docs/en/worktrees) | `--worktree`の既定は`.claude/worktrees/`なので、このリポジトリでは上記の手動作成後に対象ディレクトリから`claude`を起動する。 |

[Claude Codeの`WorktreeCreate` hook](https://code.claude.com/docs/en/hooks#worktreecreate)は既定のGit処理全体を置換し、base ref、PR起点、ローカルファイルの複製、cleanupも実装側の責務になる。配置変更だけのためには導入せず、製品固有ディレクトリは移行中の未追跡表示を防ぐ目的でgitignoreする。将来、同等のGit動作を維持したまま保存先だけを指定できるプロジェクト設定が提供された場合は、製品別アダプターとして採用を再検討する。

作業ファイルは存続期間と所有者で配置を決める。

| 種類 | 配置 | 後始末 |
| --- | --- | --- |
| PR本文、承認snapshot、検証結果など、ターンやセッションを越えて参照するプロジェクト固有ファイル | `local/agent-artifacts/` | 利用完了後に削除 |
| 再取得・再生成できるプロジェクト固有キャッシュ | `local/cache/` | 不要になった時点で削除 |
| 1コマンド内で完結するテストfixture | `mktemp`で得たシステム一時領域 | 同じプロセスの`trap`等で必ず削除 |
| OS、Swift、Xcode、Agent製品自身が管理する内部データ | 各製品が定める保存先 | 各製品のretentionとcleanupに従う |

`/private/tmp`などへ置いたファイルを後のターンやセッションで参照する運用は、cleanupを保証できずプロジェクトからも発見できないため行わない。恒久化すべき知識は`local/`に残さず、AGENTS.md、docs、ADR、GitHub Issueへ移す。

## セットアップマーカー

- 二重波括弧の大文字プレースホルダと、コロン付きのセットアップマーカー(TODO に「(setup)」とコロンを付けたもの)は `just setup-check`(`just check` に含む)が検出し、解消するまでビルドを fail させる。本スケルトンはこれらをすべて解消済みで出荷している。
- コロン付きの `TODO(defer)` マーカーは、追跡はするが正当に保留する作業(例: 法務確認待ちのライセンス確定)を表す。CI を fail させない。

## GitHub Actions の運用

- セットアップ後、各 action は commit SHA へピン留めを推奨(サプライチェーン対策)。`dependabot.yml` が github-actions を対象にするため、ピン留め後も更新 PR が出る。
- gitleaks は個人リポジトリでは追加設定不要。Organization 配下では `GITLEAKS_LICENSE`シークレット(無償申請可)の設定が必要。
- 任意の一度きりのハードニング: `bash scripts/setup-github.sh`(認証済み gh CLI が必要)でsquash のみ許可と main ルールセットを設定する。

## 変更を main へ統合する

人間・AIエージェント・使用ツールにかかわらず、この節をコミットから統合後の後始末までの具体手順の正典とする。規約と理由は`AGENTS.md`および [G-0001](./adr/governance/G-0001-merge-strategy.md)、PR本文の入力形式はリポジトリの `.github/pull_request_template.md`を参照する。ツール固有のスキルやコマンドには、この手順を複製しない。

### 1. コミット前

1. 対応Issue、assignee、Issue番号を含む作業ブランチを確認する。
2. `git status --short --branch`で対象外の変更が混在していないことを確認する。
3. `just check`をgreenにする。非自明な変更はverifierの第三者検証も通し、ハードウェア・TCC依存の変更は実機確認結果を記録する。
4. 未コミットのdiffと検証結果を報告し、利用者の変更確認を受けてからステージ・コミットする。`--no-verify`は使わない。

### 2. pushとPR作成

1. `git fetch origin`後、`origin/main`に未取得の変更がないか確認する。競合や先行変更があれば、push前に作業ブランチを更新して検証をやり直す。
2. 作業ブランチだけを`git push -u origin <branch>`でpushする。`main`へ直接pushしない。
3. PRタイトルをConventional Commits形式、72文字以内、末尾ピリオドなしにする。
4. PRテンプレートの5節(概要 / 変更内容 / 関連Issue / Squash body / チェックリスト)をすべて埋める。関連Issueは`Closes #<number>`とする。
5. 作成後にPRのbaseが`main`、headが意図した作業ブランチ、Files changedが1 Issue分だけであることを確認する。

### 3. CIとマージ前停止

1. requiredかどうかにかかわらず、PRに紐づく**全check**を確認する。現在の名称を手順へ固定せず、`gh pr checks <number> --watch`に現れるcheckを正とする。pending、failure、cancelled、timed out、action requiredを残さない。neutralやskippedは、意図した条件分岐であることを確認する。
2. redやcancelledを無視しない。原因を修正し、ローカル検証からやり直す。
3. checksがすべてgreenでも自動でマージしない。PRのbase、head、head commit、タイトル、本文、Files changed、レビュー結果を取得して報告し、 **その状態を対象とするマージ承認を得る**。これは外向き・不可逆操作の停止点とする。
4. 承認後にbase、head、head commit、タイトル、本文のいずれかが変わった場合は承認を無効とし、CI・差分確認・承認からやり直す。

### 4. squash merge

1. 承認対象として保存したPRのbase、head、head commit、タイトル、本文がGitHub上の最新状態と一致することと、全checkがgreenのままであることを確認する。
2. `gh pr merge <number> --squash --match-head-commit <承認済みhead commit>`を使い、承認後のcommit差し替えを機械的に拒否する。subjectを `<PRタイトル> (#<number>)`、bodyを**PR本文全文**にする。コミット一覧の自動生成本文へ置き換えない。
3. `gh pr view <number>`で`MERGED`、merge commit、`Closes`対象Issueのcloseを確認する。確認できない状態で後続作業へ進まない。

CLIでは承認対象のsnapshotと本文を`local/agent-artifacts/`へ保持する。承認後に同じfieldsを再取得し、`cmp`が不一致ならマージせず再承認する。

```bash
pr_number=123
pr_artifact_dir="local/agent-artifacts/pr-$pr_number"
mkdir -p "$pr_artifact_dir"
pr_snapshot_file="$pr_artifact_dir/approved.json"
current_snapshot_file="$pr_artifact_dir/current.json"
pr_body_file="$pr_artifact_dir/body.md"
gh pr view "$pr_number" \
  --json baseRefName,headRefName,headRefOid,title,body > "$pr_snapshot_file"

# このsnapshotとFiles changed・checks・reviewを提示し、マージ承認を得る。
gh pr view "$pr_number" \
  --json baseRefName,headRefName,headRefOid,title,body > "$current_snapshot_file"
cmp -s "$pr_snapshot_file" "$current_snapshot_file" || exit 1
gh pr checks "$pr_number" || exit 1
gh pr view "$pr_number" --json state,isDraft,mergeable,reviewDecision

approved_head="$(jq -r .headRefOid "$pr_snapshot_file")"
pr_title="$(jq -r .title "$pr_snapshot_file")"
jq -r .body "$pr_snapshot_file" > "$pr_body_file"
gh pr merge "$pr_number" --squash \
  --match-head-commit "$approved_head" \
  --subject "$pr_title (#$pr_number)" \
  --body-file "$pr_body_file"

# gh pr viewでマージ済みと確認した後
rm -- "$pr_snapshot_file" "$current_snapshot_file" "$pr_body_file"
rmdir -- "$pr_artifact_dir"
```

`cmp`またはcheck確認が失敗したら後続コマンドを実行しない。作業ファイルはマージ確認後に削除する。削除を自動化できない環境では、保存場所を報告して利用者に後始末を委ねる。

### 5. main同期とブランチの後始末

1. `git fetch origin`後、`git switch main`と`git pull --ff-only origin main`でローカルmainを同期する。
2. 取り込まれた変更と`git status`がcleanであることを確認する。
3. 後続のstacked branchがなければ、明示的な承認範囲を確認してからローカルブランチを`git branch -d <branch>`で削除する。remote branchはGitHubの自動削除結果を確認し、残っている場合だけ削除する。
4. ブランチ削除はマージとは別の破壊的操作である。対象を特定できない場合や、後続ブランチが参照している場合は削除しない。

### stacked branchの統合

原則として後続ブランチはpush・PR作成せず、先行PRを先にmainへsquash mergeする。squash後は先行ブランチとmainのコミットIDが異なるため、後続PRをそのまま作ると先行Issueの差分まで含まれうる。

1. 先行ブランチのtipを保持したままmainを同期する。
2. 未pushの後続ブランチは `git rebase --onto main <先行ブランチ> <後続ブランチ>`で後続コミットだけを新しいmainへ載せ直す。
3. `git diff main...<後続ブランチ>`が後続Issueの変更だけであることを確認し、 `just check`と必要な追加検証をやり直す。
4. 後続ブランチをpush済みの場合は履歴を書き換えない。新しいmainを後続ブランチへmergeして通常pushし、PR差分が後続Issueだけになることを確認する。この作業ブランチ内のmerge commitは最終的なsquashでmainには残らない。force pushは禁止する。差分を分離できなければ停止して方針を確認する。
5. 既存の後続PRが先行ブランチをbaseにしている場合は、先行PRのマージと後続ブランチの更新後に`gh pr edit <number> --base main`などでbaseをmainへ変更する。base、head、Files changed、全checkを改めて確認し、先行Issueの差分が含まれないことを確認する。
6. 後続ブランチの載せ直しと検証が終わるまで、先行ローカルブランチを削除しない。

複数の独立Issueを1PRへまとめたり、後続PRを先行PRへ向けたままmainへ統合したりしない。各Issueを順番に`main`へ統合する。

## ブランチ運用・リリース

規約: `AGENTS.md`(リポジトリ直下)。具体的な統合手順は上の「変更をmainへ統合する」。理由: [G-0001](./adr/governance/G-0001-merge-strategy.md) / [G-0002](./adr/governance/G-0002-release-strategy.md) / [G-0003](./adr/governance/G-0003-incomplete-code-integration.md)。
