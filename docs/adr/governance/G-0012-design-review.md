# G-0012: 設計判断を含む変更に同系+異種reviewerの設計レビューを課す

- ステータス: Accepted
- 日付: 2026-08-28
- 関連: #137(試験運用と証跡)/ #139(正式化)/ G-0010(無人実行と人間承認)/ `.agents/skills/verify/SKILL.md`

## Context(背景)

plan-execute-verify の検証は実装後の同系 verifier のみで、設計への敵対的検証がなかった。#111 では実装 verifier が検出した拒否漏れ 2 件がいずれも設計段階の見落としで、検出が実装後だったため修正→再検証のループが 1 周増えた(検証だけで約10万トークン)。また同系 reviewer は実装者と盲点が相関するため、実行による正解基準がない設計段階でこそモデル系統・runtimeの非相関が効く。#137 の試験運用(#128 を題材)でこの仮説を検証し、同系・異種が互いに見ていない設計欠陥を発見する相互補完と、判定が割れたときの人間裁定の成立を確認した(有望な初回結果。証跡は #137)。さらに #139 の設計(計画 v1→v6)と実装の両方で「blocking 修正後の版を独立確認する規則が無いまま、修正済み扱いで先へ進み、後続の独立検証が新たな blocking を見つける」構造が再現したため、終端規則(closure)を本 ADR の決定に含めた。

検討した代替案: (a) 全非自明変更へ設計レビューを課す ―― 自明寄りの修正まで儀式化しコストが釣り合わないため却下。(b) 実装後レビューのみ強化 ―― 設計欠陥の検出が実装後のままで手戻りが減らないため却下。(c) 異種 reviewer 利用不能時に別 Agent へ自動 fallback ―― 意図しない API 利用料・ログイン要求・使用量消費と、要求した異種性が黙って劣化する問題があるため却下。(d) モデル・effort 設定のリポジトリ管理 ―― 認証・課金・環境は個人事情であり、リポジトリは schema と意味論だけを持つべきため却下(G-0009 の `local/` 配置と整合)。

## Decision(決定)

1. **設計判断を含む変更**(トレードオフの選択、境界・不変条件の定義、実装方式の採用判断)では、計画に 4 項目(守る不変条件 / fail-open・fail-closed の向き / 境界表 / 自動検証で拾えない失敗モード)を明記し、人間の承認前に**同系+異種reviewer(外部reviewer)の独立設計レビュー**を通す。自明な修正には課さない。手順の正典は `.agents/skills/verify/SKILL.md`、基準の正典は `.agents/skills/verify/references/design-reviewer.md`。
2. **判定と実行状態を別概念にする**。判定は 4 分類(READY / REVISE / DECISION_NEEDED / INCONCLUSIVE)で、reviewer が正常実行され有効な出力を返した場合だけ記録する。起動・環境の失敗は実行状態(COMPLETED / NOT_CONFIGURED / UNAVAILABLE / DIVERSITY_UNSATISFIED)と理由語彙で記録する。語彙の正典は `.agents/agent-review.schema.json` に置き、他所へ複製しない。
3. **同系は必須層(fail-closed)、異種は追加層(fail-open + 開示)**。同系 reviewer が成立しない場合はレビュー不成立とし、人間の明示的 waiver の記録なしに承認へ進めない。異種の利用不能は理由を記録して続行し(DEGRADED)、その状態を人間へ提示する。
4. **異種 reviewer(外部 reviewer)の設定は個人ローカル**(`local/agent-review.json`、任意・非コミット)。設定ファイル自体が無ければ異種は実行しない(NOT_CONFIGURED)。設定ファイルの自動生成・CLI の自動探索・自動起動・別 Agent への黙った fallback を行わない。
5. **多様性は3レベルを正式化し、設定済み profile では必須とする**(弱い保証を無意識に選ばせない)。runtime-only = 主導と reviewer の runtime が異なれば成立(解決モデル unconfirmed でも成立するが「異種モデル」とは呼ばない)/ model-family = 解決モデルの実測で主導と異なる系統なら成立 / runtime-and-model-family = 両方が異なる場合のみ成立。model 系レベルで解決モデルが unconfirmed または系統 unknown なら DIVERSITY_UNSATISFIED とし、**要求値で代用しない**。FULL =「profile で明示したレベルを満たし正常完了」、DEGRADED =「設定なし・利用不能・要求した多様性を確認できなかった」。要求レベルと成立レベルの両方を記録する。「異種モデル reviewer」という語は model 系レベルを実際に満たした場合に限る。
6. **実装後は同系 verifier 必須を維持**し、高リスク領域(セキュリティ境界・Agent hook・並行性・TCC・データ移行)に限り異種 verifier を追加する。
7. **tool 制限の製品差を認めて記録する**。claude-code-cli / github-copilot-cli は可視 tool と実行許可の 2 層で保証し、tool allowlist を持たない codex-cli は sandbox +使い捨て worktree +起動前後 snapshot 比較の事後検査で同等の最終保証を作る(実装は `scripts/design-review.sh`)。機械的に隠せない tool はプロンプト禁止+ tool log 検出で扱い、「利用不能」と主張しない。
8. **人間の承認点(計画承認・変更確認・マージ承認)は減らさない**。設計レビューは承認の入力であり代替ではない(G-0010 を変更しない)。
9. **レビューの closure を設計・実装共通の終端規則とする**。レビュー対象は round 開始前に固定する(設計 = 計画の版または内容 hash、実装 = HEAD・tracked diff・untracked manifest を含む snapshot)。blocking 対応で対象を変更したら、旧 snapshot への READY / PASS は新 snapshot へ引き継がず、fresh context の closure review で再確認する。blocking は「修正して再確認 / 一次情報による反証 / 人間へ委譲して waiver 記録」のいずれかへ必ず分類し、未処置・未再確認の blocking が残る状態を完了と呼ばない。closure round は各段階で最大2回(初回レビューを含めない。停止条件の正典は round 数で、トークン・時間は記録のみ)。上限到達で未収束なら主導 Agent だけで終端せず人間へ裁定を求め、裁定記録(対象 snapshot・残指摘・round 数と使用量・提示選択肢・裁定結果・判断理由と日付)を残す。手順の詳細は `.agents/skills/verify/SKILL.md`「レビューのclosure」を正典とする。

## Consequences(結果)

- 得るもの: 設計欠陥の検出が実装前へ移り手戻りが減る。異種reviewerの非相関(runtime差・モデル系統差)により同系だけでは見えない欠陥(境界・検証経路の穴)を拾える。実行状態の分離により「認証失敗を判定として誤魔化す」劣化が構造的に起きない。
- 失うもの: 設計判断を含む変更 1 件あたりレビュー 2 系統ぶんのトークンと数分の壁時間(#137 実測: 約10万トークン・並列3分)。異種 reviewer の CLI 仕様変更への追随義務(launcher に集約して影響を局所化する)。
- 規律で残る部分: 生出力の即時保存・DEGRADED の人間提示は機械強制されない(記録先が Issue コメントであり強制点がない)。launcher と共通 validator・スタブテストが機械検証できるのは起動・分類・記録のロジックまでで、実 CLI の認証・課金・解決モデルは実運用でしか確認できない。
- 成立しなくなる条件: 対応 runtime の CLI が非対話実行・sandbox・tool 制限のいずれかを廃止した場合、その runtime の保証設計を見直す(本 ADR を書き換えず、新しい ADR で改訂する)。
