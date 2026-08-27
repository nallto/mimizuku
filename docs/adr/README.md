# ADR(Architecture Decision Records)

設計上の重要な判断を、背景・決定・結果とともに記録する。「なぜその設計にしたか」を残し、後から参加する人間や AI が経緯を追えるようにする。

このフォルダは 2 種類を分けて置く:

- **製品 / アーキテクチャ**判断: `NNNN-*.md`(本ディレクトリ)。
- **プロセス / 統治**判断: `governance/G-NNNN-*.md`。

分けることで、製品判断と統治判断が同じ連番で混ざらず、製品 ADR を 0001 からきれいに採番できる。

## 製品判断

| ID | タイトル | ステータス |
| --- | --- | --- |
| [0001](./0001-minimum-os-target.md) | 最小デプロイターゲットは macOS 26、Apple Silicon 限定 | Accepted |
| [0002](./0002-license.md) | ライセンスは Apache-2.0 | **Proposed**(法務確認待ち・公開のブロッカー) |
| [0003](./0003-module-architecture.md) | App ターゲット + 単一 SPM パッケージ(MimizukuCore)で開始 | Accepted |
| [0004](./0004-xcode-project-generation.md) | Xcode プロジェクトは XcodeGen で生成(project.yml を正典) | Accepted |
| [0005](./0005-product-scope-expansion.md) | プロダクトスコープ拡張、実装計画を「記録先行」6 フェーズへ再編 | Accepted |
| [0006](./0006-recording-format-and-layout.md) | 録音は CAF(PCM)+ 停止時 AAC 変換、ストリーム毎 2 ファイル | Accepted |
| [0007](./0007-session-metadata-storage.md) | セッションの正典はJSONスナップショット、処理中はJSONLジャーナルにする | Accepted |
| [0008](./0008-three-pane-navigation.md) | 3ペインUIは標準SwiftUI構成、activation policyは動的切替 | Accepted |
| [0013](./0013-echo-cancellation-webrtc-aec3.md) | エコーキャンセルは WebRTC AEC3、処理後音声を録音・文字起こしに使う | Superseded by ADR-0014 |
| [0014](./0014-aec-processed-microphone-fail-closed.md) | AEC処理済みマイクだけを正式音源とし、参照喪失時はfail-closedにする | Accepted |
| [0015](./0015-aec-diagnostics-storage.md) | AEC診断データは$XDG_STATE_HOMEへ分離し、揮発性起動引数で有効化する | Accepted |
| [0016](./0016-capture-stall-detection.md) | 捕捉の停止はソース内部で再構築し、回復しなければfail-closedにする | Accepted |
| [0017](./0017-capture-gap-silence-fill.md) | 捕捉の欠落区間は、AECの外側で実測長の無音を挿入して時間軸を保つ | Accepted |

## 統治判断

| ID | タイトル | ステータス |
| --- | --- | --- |
| [G-0001](./governance/G-0001-merge-strategy.md) | マージは squash 統一、コミット規約は PR タイトルで強制 | Accepted |
| [G-0002](./governance/G-0002-release-strategy.md) | main のみ + release-please、release ブランチ常設なし | Accepted |
| [G-0003](./governance/G-0003-incomplete-code-integration.md) | 未完成コードは keystone 優先、flag は削除期限つき | Accepted |
| [G-0004](./governance/G-0004-execution-modes.md) | 実行モードは承認駆動が既定、ループは条件+ガードレールつき | Superseded by G-0008 |
| [G-0005](./governance/G-0005-actions-pinning.md) | GitHub Actions は full-length commit SHA へピン留め | Accepted |
| [G-0006](./governance/G-0006-agent-workflow-source.md) | Agent共通ワークフローは`.agents/skills`を正典とする | Accepted |
| [G-0007](./governance/G-0007-markdown-soft-wrap.md) | Markdownはソフトラップを前提に整形する | Accepted |
| [G-0008](./governance/G-0008-unified-agent-workflow.md) | Agent作業を単一ワークフローと利用者指定の停止条件に分離する | Accepted |
| [G-0009](./governance/G-0009-agent-local-artifact-placement.md) | Agentのworktreeと作業ファイルをプロジェクト内に置く | Accepted |
| [G-0010](./governance/G-0010-unattended-agent-work.md) | 無人実行はdraft PRまで許可し、報告は優先度つきキューで1件ずつ行う | Accepted |
| [G-0011](./governance/G-0011-human-only-release-pr-merge.md) | release-please PRのマージ実行は人間に限定する | Accepted |

## 書き方

- 新しい判断をしたら [`template.md`](./template.md) をコピーし、正しい種別で次の連番で追加する。
- ステータスは `Proposed` → `Accepted` →(必要なら)`Superseded by ADR-NNNN`。
- 一度 `Accepted` にした ADR は原則書き換えず、新しい ADR で上書きする(決定の履歴を残す)。
- 手順の正典は`.agents/skills/adr/SKILL.md`。Claude Codeでは`/adr <タイトル>`でも起動できる。
