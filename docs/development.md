# 開発ガイド

開発者向けのセットアップと、このリポジトリの「強制装置」の全体像(利用者向け情報は README)。

## セットアップ

前提は [mise](https://mise.jdx.dev/) と **Xcode 26**(App Store / Apple Developer より)。補助ツールの版数は `mise.toml` が SSOT。Swift コンパイラは Xcode 由来。

```bash
mise install    # just / jq / swiftlint / swiftformat
just --list     # 利用可能なタスク
just check      # CI と同一の検証
```

## 検証の原則

- **`just check` = CI。** ローカルで green なら CI も green(乖離したらバグとして直す)。CI はデプロイターゲット(ADR-0001)に合わせ `macos-26`(Apple Silicon)で実行する。
- `just check` = `setup-check` + `lint`(swiftlint) + `fmt-check`(swiftformat) + `test` (MimizukuCore の swift test)。
- **`just check` は純ロジックのみを検証する。** マイク / システム音声 / TCC / モデルアセットの挙動はホスト型ランナーで実行できない(domain-pitfalls #8)。それらは各スライスに記した手動テストで人間がローカル検証する。

## ログレベルの方針(os.Logger)

unified logging の実仕様に基づく使い分け。**`Logger.warning()` は使わない** ―― macOS の統一ログに Warning という独立種別は無く、`warning()` は **Error 種別として記録される**(想定内イベントが Console 上で Error に見える罠。S3 実装時に発覚)。

| レベル | 永続化 | 使いどころ | 例 |
|---|---|---|---|
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

- **CLI ツール(just / jq / swiftlint / swiftformat)**: mise がプロジェクト単位で隔離する。インストール先は mise 管理下(`~/.local/share/mise` 等)で、Homebrew のようなグローバル汚染をせず、`mise.toml` で版数もプロジェクトに固定される。複数プロジェクトの併存もこれで分離できる。**この層は現状すでに隔離されている。**
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
|---|---|---|
| リポジトリ設定 | ブランチ保護 / squash のみ | main の不変条件(G-0001) |
| CI | ci / pr-title / security | 検証・コミット規約・シークレット混入 |
| Claude Code | `.claude/settings.json` permissions | 秘密情報の読取・force push の拒否 |
| Claude Code | `hooks/protect.sh`(PreToolUse) | 危険コマンドのブロック(2 層目) |
| Claude Code | `hooks/post-edit.sh`(PostToolUse) | 編集ごとの自動整形(swiftformat) |
| 規約文書 | AGENTS.md | 機械強制できない非自明ルールのみ |

規約文書は最弱の層。新しいルールを作るときは、まず上の層で強制できないかを検討する。

## セットアップマーカー

- 二重波括弧の大文字プレースホルダと、コロン付きのセットアップマーカー(TODO に「(setup)」とコロンを付けたもの)は `just setup-check`(`just check` に含む)が検出し、解消するまでビルドを fail させる。本スケルトンはこれらをすべて解消済みで出荷している。
- コロン付きの `TODO(defer)` マーカーは、追跡はするが正当に保留する作業(例: 法務確認待ちのライセンス確定)を表す。CI を fail させない。

## GitHub Actions の運用

- セットアップ後、各 action は commit SHA へピン留めを推奨(サプライチェーン対策)。`dependabot.yml` が github-actions を対象にするため、ピン留め後も更新 PR が出る。
- gitleaks は個人リポジトリでは追加設定不要。Organization 配下では `GITLEAKS_LICENSE`シークレット(無償申請可)の設定が必要。
- 任意の一度きりのハードニング: `bash scripts/setup-github.sh`(認証済み gh CLI が必要)でsquash のみ許可と main ルールセットを設定する。

## 実行モード

既定は承認駆動(計画 → 承認 → 実行 → 検証)。ループ実行の条件とガードレールは[G-0004](./adr/governance/G-0004-execution-modes.md)。本プロジェクトの核はハードウェア/権限依存のため承認駆動のみで、無人ループやサンドボックス検証には委任できない。

## ブランチ運用・リリース

規約: `AGENTS.md`(リポジトリ直下)。理由: [G-0001](./adr/governance/G-0001-merge-strategy.md) / [G-0002](./adr/governance/G-0002-release-strategy.md) / [G-0003](./adr/governance/G-0003-incomplete-code-integration.md)。
