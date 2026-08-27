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

## AEC 診断試行(#75 / ADR-0015)

回り込み抑制の非決定性を切り分けるための開発者専用診断。同一試行の APM 実入出力(raw capture / render 参照 / 処理後 capture)と正規化前後の実測時刻をローカル保存し、オフラインで数値比較する。診断データはデバイス外へ出さず、リポジトリへコミットしない。

### 記録(実機)

1. 既存の Mimizuku を終了する(menu bar から Quit。二重起動は tap が競合する)。
2. **揮発性の起動引数**付きで起動する(`defaults write` は使わない ―― 切り忘れで raw 録音が全セッション継続する事故を防ぐ。ADR-0015):

   ```bash
   open -n /path/to/Mimizuku.app --args -AecDiagnosticsEnabled YES
   ```

3. マイクを含むモードで録音を開始・終了する。試行ごとに `$XDG_STATE_HOME/mimizuku/aec-diagnostics/<yyyyMMdd-HHmmss>/`(既定 `~/.local/state/...`)へ音声 4 ファイル(capture-raw / capture-processed / render-received / render-fed)+ frames.jsonl + speech.jsonl + meta.json が保存される。約 1.4GB/時を消費する。 speech.jsonl の start/end はセッション原点(runStreams 開始)へシフト済みの値で、mic 解析原点(frames.jsonl の speechTimeSeconds)との対応は meta.json の speechStartOffsets(mic の値を引く)で取る。
4. **controlled test では人間は発話しない**(近端発話を除外できない窓は far-end 単独と断定できず、残留比を抑圧量として解釈できない)。同一テスト音源をスピーカーで再生し、複数回試行して変動を比較する。

### 解析

```bash
just aec-diag ~/.local/state/mimizuku/aec-diagnostics/<trial>
```

- 3 対を窓別に報告する: raw × render-received(捕捉クロック・参照信号)/ raw × render-fed(APM が見た参照系列。音声の順序は fedIndex(受付順)が正典で、capture との対応点は各 fed の hostTime から窓ごとに復元する)/ raw × processed(処理前後電力比)。
- writer のバッファ溢れ・書き込み失敗があった試行(meta.json の valid=false)や CAF 長と JSONL が不整合の試行は、正式数値を出さず理由付きで拒否される ―― これは**診断 writer 自身の欠損であって製品挙動の異常ではない**。試行を破棄してやり直す。

### 指標の読み方

- **raw × render-received**: 捕捉した時点の参照そのもの(tap → 変換 → framer 後、aligner 介入前)と raw マイクの実時間比較。ここの delay は正規化 host time 上の相関ピークによる**有効エコー遅延の推定値**(音響伝搬に加え入出力バッファ・デバイス時刻・timeline 正規化を含む)。十分な有効窓があり、同一条件の複数試行で同じクラスタを形成した場合にだけ解釈する ―― 単発の推定値(特に相関が低いもの)を fixed delay 等へ投入しない。変動の読み方は分離する: **delay の変動**は音響条件・出力経路・入出力バッファ・時刻同期を疑う材料、**capture/render driftPPM の変動**は各デバイスのクロック・timestamp・timeline を疑う材料。条件を固定した複数試行でも変動が残る場合に、同期層の疑いが強まる。
- **raw × render-fed**: aligner 介入(gap-fill 無音・lead/late/overflow 破棄)後に **APM が実際に受け付けた**参照との比較。received と一致しない分が aligner・給餌の影響。
- **残留比**(raw × processed): `10·log10(P_raw / P_processed)` dB。大きいほど処理後の残留が少ない。ただし raw に近端発話・ノイズが含まれる窓では抑圧量を意味しない(**ERLE ではない**)。controlled test(人間は発話しない)の echo-dominant 窓に限って解釈する。残留比は APM 処理前後の**総電力差**であり、controlled test でもエコー除去量だけを表さない(ノイズ抑制など APM 全体の処理を含む)。APM 内部 ERLE との不一致は直ちに異常ではない。
- **inputChunk の 3 指標の違い**: `timingDeltaMs` = 個々のコールバック到着の単発ジッタ(実測 − サンプルクロック予測)。`rebase` = 閾値超の不連続(本物の欠落・デバイス変更)で実測へ追従した回数。`driftPPM` = 長期のサンプルクロック進行レート差(蓄積量 ÷ 経過時間)。ジッタが大きくても drift が小さければクロックは健全。
- **APM 統計**(erl / erle / delay / median / std / divergent / residual)は **APM 内部推定値**であり、実測の除去量・遅延そのものではない。CLI の遅延推定(実測)と一致しなくても直ちに不具合ではない ―― 大きく乖離し続ける場合に「APM が正しく収束していない」仮説の材料にする。delay median/std は初回取得後 1 秒集約へ切り替わる。
- **「判定なし」の理由**は保守的な除外であり、多くは正常:

  | reason | 意味 | 対応 |
  | --- | --- | --- |
  | windowTooShort / insufficientRenderContext | 窓長または解析用の前方参照文脈が足りない(epoch 端・開始端) | 正常な除外。試行を長くすれば減る |
  | zeroSignal / renderTooQuiet | 無音・参照レベル不足 | テスト音源の音量・再生区間を見直す |
  | lowCorrelation | 相関が立たない(回り込みが小さい・SNR 不足・近端ノイズ・無相関区間・参照不一致) | 頻発するなら音源レベル・距離と、参照とマイクの対応の両方を疑う |
  | tiedPeaks | 周期信号で一意に決まらない | 音楽等の周期素材を避け、発話素材にする |
  | boundaryPeak | ピークが探索境界(真の遅延が範囲外の可能性) | 全窓で出るなら実遅延が想定範囲外のサイン |

### 原因切り分け

| 観測 | 疑う層 |
| --- | --- |
| raw×received の delay が試行ごとに変動 | 音響条件・出力経路・入出力バッファ・時刻同期。条件を固定した複数試行でも変動するなら同期層(捕捉クロック・tap・timeline 正規化)の疑いが強まる |
| capture / render の driftPPM が変動 | 各デバイスのクロック・timestamp・timeline 正規化 |
| raw×received は安定、raw×fed だけ変動 | aligner・gap-fill・lead/late/held drop・recovery(frames.jsonl の event を突き合わせる) |
| fed まで安定、残留比や APM 統計だけ変動 | APM の収束・参照レベル・音響条件 |
| processed の残留は小さいのに Speech だけ誤認識 | Speech の認識条件(speech.jsonl と speechTimeSeconds で該当区間を特定し、capture-processed.caf の該当区間を試聴) |
| valid=false | 診断 writer 自身の欠損(製品挙動ではない)。試行を破棄して再試行 |

### 試験プロトコル(runbook)

再現可能な比較のため、以下を**最初の計測時に確定して Issue #75 に記録し、以後の全試行で固定**する(実測に基づく具体値は捏造せず、複数試行のベースライン取得後に有用と確定したものだけを docs へ昇格させる)。

- テスト音源: 発話を含む固定のファイル 1 つと再生区間(周期的な音楽は tiedPeaks になりやすいので避ける)。
- 出力デバイス・システム音量・スピーカーとマイクの位置関係(距離を変えない)。
- 1 試行の長さ(目安 60 秒以上)とウォームアップの扱い。注意: 「判定なし」は raw×render の相関条件(参照文脈不足・低相関・無音・周期信号)によるもので **APM の収束とは独立**。APM のウォームアップは processed の残留比・APM 統計の序盤区間として扱い、「判定なし」を収束待ちと解釈しない。
- 試行回数: mic-only / both の各モードで最低 3 回(1 回の試行で判断しない)。
- 試行間で変更してよい変数は **1 つだけ**。それ以外は固定する。
- 記録は `just aec-diag` が末尾に出力する**試行サマリー行**(下記の列)を Issue #75 の表へそのまま貼る。delay は「estimate 窓の中央値 / estimate になった窓の割合」、driftPPM は capture / render の 2 列(両者は大きく異なり得る)、ERLE med は APM 内部 ERLE の中央値。「Speech 回り込み」だけは speech.jsonl を見て手動判定で埋める:

  ```text
  | trial | mode | received delay med/valid | fed delay med/valid | capture driftPPM | render driftPPM | 残留比 med | APM ERLE med | events | Speech回り込み |
  ```

### チューニング規律

- **計測結果なしの固定 delay・ミュート・閾値調整はしない**(#75 の受け入れ条件)。同期・参照品質(raw×received / raw×fed)が安定するまで APM パラメータに触れない。
- 1 回の試行だけで判断しない。変更前後は**同一条件で複数試行**して比較する。
- 1 度に変更する変数は 1 つ。fixed delay・ミュート・閾値を変更した場合は、根拠(どの指標がどう変わったか)と前後比較を Issue へ残す。
- 閾値の「良い/悪い」は実機ベースライン取得前に決め打ちしない。

### 削除

診断データの保持・削除は手動(自動ローテーションなし)。不要になったらディレクトリごと削除する:

```bash
rm -rf ~/.local/state/mimizuku/aec-diagnostics
```

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
| Claude Code / Codex / GitHub Copilot CLI・cloud agent | `scripts/agent-hooks/protect-command.sh`(PreToolUse) | 危険コマンドのブロック(2層目) |
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
| `.github/copilot-instructions.md` | GitHub Copilotの各surfaceから共通規約へ接続 | 手順を持たない薄いアダプター |
| `.github/agents/` | GitHub Copilot固有のcustom agent定義 | tool制限と共通基準への参照だけ |
| `.github/hooks/` | GitHub Copilot CLI・cloud agentのhook接続 | GitHub Copilot固有 |
| `scripts/agent-hooks/` | Agent間で共用できる決定的なhook処理 | 実装の正典 |
| `.claude/settings.json` | Claude Codeの権限とhook接続 | Claude Code固有 |
| `.codex/hooks.json` | Codexのhook接続 | Codex固有 |
| `.claude/hooks/post-edit.sh` | Claude Codeの編集イベントから単一ファイルを整形 | イベント形式が異なるため固有 |

Claude Codeは`.claude/skills/`、CodexとGitHub Copilotは`.agents/skills/`をプロジェクトskillの探索場所とする。[GitHub Copilotは`.agents/skills/`をproject skillとしてnative探索できる](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills)ため`.github/skills/`へ複製しない。Claude Codeの`.claude/skills/`には対応する共通`SKILL.md`を読む指示だけを置き、手順本文は複製しない。

commandsはskillと機能が重複し、Claude Codeでは同名skillが優先されるため、 `.claude/commands/`に`adr`、`check`、`verify`を重ねて持たない。slash commandは対応するClaude Code skillから提供する。

PreToolUseのshell入力はClaude Code、Codex、GitHub CopilotのPascalCase `PreToolUse`で`tool_input.command`として受け取れるため、危険コマンド判定を共通化する。GitHub Copilotの接続は`.github/hooks/mimizuku-policy.json`に置き、[公式にrepository hookを読み込むCopilot CLIとcloud agent](https://docs.github.com/en/copilot/reference/hooks-reference)を対象とする。Copilotのcommand hookは非ゼロ終了時にfail-closedだがtimeout時はfail-openになるため、10秒以内に完了する決定的なローカル判定だけを置く。PostToolUseは、Claude CodeのEdit/Writeが単一の `file_path`を渡すのに対し、Codexの`apply_patch`は複数ファイルを扱いうるため、自動整形hookを無理に共通化しない。CodexとGitHub Copilotでは最終的な`just check`を整形保証とする。

`.codex/hooks.json`はプロジェクト設定として信頼された環境で有効になる。[GitHub Copilotのrepository hookはCLIとcloud agentだけが対応する](https://docs.github.com/en/copilot/reference/hooks-reference)ため、Xcode・IDE Chat・code reviewでは`.github/copilot-instructions.md`とCIを保証線とする。Agentのsandboxや権限モデルは製品ごとに異なるため完全には共通化せず、禁止理由を `AGENTS.md`、共用できる判定を`scripts/agent-hooks/`、接続と追加権限を製品別設定に分離する。個人用の`.claude/settings.local.json`はGit管理しない。

### Agent設定を変更するとき

`.agents/`、`.claude/`、`.codex/`、`scripts/agent-hooks/`などに触れる前に `.agents/skills/agent-config/SKILL.md`を読み、`.agents/integrations.json`に登録された全Agentとfallbackについて影響表を作る。

共通skillを追加すると、`just agent-config-check`はregistryで`adapter`方式に登録された全Agentへ同名アダプターがあることを要求する。逆に、共通skillのない孤立アダプターも拒否する。frontmatterはRuby標準のPsychでYAMLとして解析し、文字列の`name`と`description`を要求する。Rubyは最小対応環境のmacOS 26とCI runnerに含まれる`/usr/bin/ruby`を使い、追加のgemは必要としない。Rubyを使わない場合はYAML parserの自作ではなく、再現可能なparserを`mise.toml`へ追加して置き換える。

adapterは探索と製品固有設定だけを持つ薄い入口なので24行を上限とする。超える場合は共通skillや参照資料へ移せる手順本文が混入していないか確認する。共通skillと同名のClaude Code commandは、個別の名前一覧ではなく全共通skillを基準に拒否する。

成功中の現構成だけでは、adapter欠落時などの失敗分岐にあるshell互換性問題を検出できない。構成検査ではRuby欠落を模擬し、一時fixtureへadapter欠落、同名command、不正YAML、adapter肥大をそれぞれ作り、意図した診断でfailすることも確認する。

新しいAgent製品へ正式対応する場合は、registryへ次を登録する。

- `id`: 製品を識別する安定した名前
- `instructions.mode`: `AGENTS.md`を直接使う`native`、製品別instructionsから接続する`adapter`
- `instructions.path`: 製品が読む規約またはadapterのパス。`adapter`では`source`に正典の`AGENTS.md`も記録する
- `skills.mode`: 共通skillを直接探索する`native`、製品別入口を置く`adapter`、指示ファイルから読む`instructions`
- `skills.path`: 探索または入口に使うパス
- `hooks`: 共通hookへ接続する製品別設定ファイル

registryにない未知のAgentは`AGENTS.md`から`.agents/skills/`を読むfallbackで作業できるが、製品固有のskill自動探索やhook動作までは保証しない。正式対応へ昇格するときにregistry、接続層、既存全skillへの到達方法、手動確認結果を同じPRへ追加する。

GitHub Copilotでは`.github/copilot-instructions.md`を全surfaceの入口とする。[CLIは`@../AGENTS.md`をimport](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)し、importを解釈しないsurfaceには同ファイルから`AGENTS.md`と関連する`.agents/skills/*/SKILL.md`を全文読むよう指示する。custom verifierは`.github/agents/verifier.agent.md`で[tool alias](https://docs.github.com/en/copilot/reference/custom-agents-configuration)の`read`、`search`、`execute`だけを許可し、共通の検証基準を参照する。

CIで確認できるのはファイル構造、YAML、参照、hook判定までである。製品上のinstructions参照、skill列挙、project trust、hook発火、verifierのtool制限は、新規sessionで手動確認しPR本文へ結果または未確認理由を残す。GitHub CopilotではXcodeの新規Chatと、Copilot CLIまたはcloud agentのhook発火を分けて確認する。

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
| 報告待ちの通知(1件1ファイル) | `local/agent-artifacts/report-queue/`(メインチェックアウト基準。G-0010 決定10) | 報告して判断が済んだ時点で削除 |
| 再取得・再生成できるプロジェクト固有キャッシュ | `local/cache/` | 不要になった時点で削除 |
| 1コマンド内で完結するテストfixture | `mktemp`で得たシステム一時領域 | 同じプロセスの`trap`等で必ず削除 |
| OS、Swift、Xcode、Agent製品自身が管理する内部データ | 各製品が定める保存先 | 各製品のretentionとcleanupに従う |

`/private/tmp`などへ置いたファイルを後のターンやセッションで参照する運用は、cleanupを保証できずプロジェクトからも発見できないため行わない。恒久化すべき知識は`local/`に残さず、AGENTS.md、docs、ADR、GitHub Issueへ移す。

## 無人実行と報告キュー

承認者が応答できない時間帯も、承認を必要としない作業は進める。停止点は「人しかできないこと」に限る。許可・禁止の境界と理由は[G-0010](./adr/governance/G-0010-unattended-agent-work.md)、報告の具体手順は`.agents/skills/report-queue/SKILL.md`を正典とする。ツール固有のスキルへ手順を複製しない。

無人実行の境界:

| 区分 | 内容 |
| --- | --- |
| 許可 | 作業ブランチへのpush、draft PRの作成・更新、`just check`、docs・ADR・Issueへの記録 |
| 禁止 | `main`への直接push、あらゆるmerge(= PRの統合。作業ブランチへコンフリクトなしでmainを取り込むマージは「作業ブランチへのpush」として許可に含む)、ブランチ削除、force push、リポジトリ設定変更、リリース・配布・告知・リポジトリ外サービスへの送信、秘密情報の読み書き、実機・TCC検証の完了判定。このうち`main`への直接pushとforce pushは共通hook(`scripts/agent-hooks/protect-command.sh`)と`main`ルールセットでも拒否されるが、作業ブランチの削除は機械的に止まらない |
| 着手範囲 | 承認済み計画の続行と、承認を要さない作業に限る。新たに非自明な変更の着手判断が必要になったら、着手せず計画案をキューへ積んで停止する |
| 変更確認 | 無人経路ではコミット前の変更確認を受けられないため、コミットとpushを行い、確認はdraft PRのdiffで事後に受ける(G-0010 決定7)。統合前の承認は省略しない |
| 必須 | 作成するPRはdraft。`needs-human`ラベルと本文の「人の介在が必要な項目」節を伴わせる |
| 作業場所 | `local/worktrees/<issue番号>-<短い説明>/`。利用者が使うmain checkoutを占有しない |

報告キューは`local/agent-artifacts/report-queue/`に1件1ファイルで置く。パスはworktree内ではなく**メインチェックアウトのルート**基準で解決する(worktreeは撤収で消えるため、そこへ積むと報告待ちが失われる)。本ファイルは基準だけを示し、解決方法、優先度規則、ファイル形式、報告手順は`.agents/skills/report-queue/SKILL.md`を正典とする。

定期巡回の内容は`.agents/skills/patrol/SKILL.md`で定義する(G-0010 決定3)。実行間隔と稼働時間帯は各自のAgent製品側でローカルに登録し、リポジトリへ焼き込まない。夜間に限定せず、休日や日中の中断中も同じ扱いとする。

製品別のローカル登録手順:

- **Claude Code**: 定期実行の機構(スケジュール機能、またはOSのcron / launchdからの`claude -p "/patrol"`起動)へ`/patrol`を登録する。登録は`~/.claude/`配下やcrontab等の個人ローカル設定で行い、コミットしない。
- **定期実行機構を持たないAgent(codex / github-copilot / 未登録)**: 作業セッションの開始時に`patrol` skillを手動で実行する(セッション開始時の報告キュー確認は`report-queue` skillの義務でもある)。
- いずれの経路でも、巡回が守る境界は本節の許可・禁止表であり、登録方法によって変わらない。

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
4. 未コミットのdiffと検証結果を報告し、利用者の変更確認を受けてからステージ・コミットする。`--no-verify`は使わない。無人実行では変更確認を受けられないため、コミットしてdraft PRのdiffで事後に確認を受ける(「無人実行と報告キュー」およびG-0010 決定7)。それ以外の手順は同じで、`just check`と第三者検証を省略しない。

### 2. pushとPR作成

1. `git fetch origin`後、`origin/main`に未取得の変更がないか確認する。競合や先行変更があれば、push前に作業ブランチを更新して検証をやり直す。
2. 作業ブランチだけを`git push -u origin <branch>`でpushする。`main`へ直接pushしない。
3. PRタイトルをConventional Commits形式、72文字以内、末尾ピリオドなしにする。
4. PRテンプレートの必須5節(概要 / 変更内容 / 関連Issue / Squash body / チェックリスト)をすべて埋める。任意節「人の介在が必要な項目」は該当時のみ残し、無ければ見出しごと削除する(空節をsquash本文へ残さない)。関連Issueは`Closes #<number>`とする。
5. 作成後にPRのbaseが`main`、headが意図した作業ブランチ、Files changedが1 Issue分だけであることを確認する。
6. 無人実行で作るPRは`--draft`とし、`needs-human`ラベルを付ける。人の介在が必要な項目を空欄にしたまま作らない。

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

### リリースPRのworkflow承認

release-pleaseのリリースPR(`github-actions[bot]`作成)は、Actionsの承認ポリシーによりworkflowが毎回`action_required`で止まり、必須チェックが走らないままマージ不能(`BLOCKED`)になる(#131。採用した方針は「人が承認する運用」)。リリースPRをマージする前に、人がworkflowを承認してCIを回す。

```bash
gh run list --branch release-please--branches--main --limit 3 \
  --json databaseId,status,conclusion
# action_required の run ごとに承認する(PR画面の "Approve and run workflows" でも可)
gh api -X POST repos/{owner}/{repo}/actions/runs/<run_id>/approve
```

リリースPRはmainが進むたびにrelease-pleaseが更新するため、承認はマージ直前に行う(headが変わると再承認が必要)。workflowの承認とマージはどちらも無人実行の禁止事項であり、人が行う。
