# ADR(Architecture Decision Records)

設計上の重要な判断を、背景・決定・結果とともに記録する。「なぜその設計にしたか」を残し、後から参加する人間や AI が経緯を追えるようにする。

このフォルダは 2 種類を分けて置く:

- **製品 / アーキテクチャ**判断: `NNNN-*.md`(本ディレクトリ)。
- **プロセス / 統治**判断: `governance/G-NNNN-*.md`。

分けることで、製品判断と統治判断が同じ連番で混ざらず、製品 ADR を 0001 からきれいに採番できる。

## 製品判断

| ID | タイトル | ステータス |
|----|----------|-----------|
| [0001](./0001-minimum-os-target.md) | 最小デプロイターゲットは macOS 26、Apple Silicon 限定 | Accepted |
| [0002](./0002-license.md) | ライセンスは Apache-2.0 | **Proposed**(法務確認待ち・公開のブロッカー) |
| [0003](./0003-module-architecture.md) | App ターゲット + 単一 SPM パッケージ(MimizukuCore)で開始 | Accepted |
| [0004](./0004-xcode-project-generation.md) | Xcode プロジェクトは XcodeGen で生成(project.yml を正典) | Accepted |

## 統治判断

| ID | タイトル | ステータス |
|----|----------|-----------|
| [G-0001](./governance/G-0001-merge-strategy.md) | マージは squash 統一、コミット規約は PR タイトルで強制 | Accepted |
| [G-0002](./governance/G-0002-release-strategy.md) | main のみ + release-please、release ブランチ常設なし | Accepted |
| [G-0003](./governance/G-0003-incomplete-code-integration.md) | 未完成コードは keystone 優先、flag は削除期限つき | Accepted |
| [G-0004](./governance/G-0004-execution-modes.md) | 実行モードは承認駆動が既定、ループは条件+ガードレールつき | Accepted |
| [G-0005](./governance/G-0005-actions-pinning.md) | GitHub Actions は full-length commit SHA へピン留め | Accepted |

## 書き方

- 新しい判断をしたら [`template.md`](./template.md) をコピーし、正しい種別で次の連番で追加する。
- ステータスは `Proposed` → `Accepted` →(必要なら)`Superseded by ADR-NNNN`。
- 一度 `Accepted` にした ADR は原則書き換えず、新しい ADR で上書きする(決定の履歴を残す)。
- 手順は adr スキル、起票は `/adr <タイトル>` コマンドでも可能。
