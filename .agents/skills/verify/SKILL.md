---
name: verify
description: 独立したverifierサブエージェントによる敵対的検証を行う。非自明な変更の完了確認、要求とdiffの突き合わせ、第三者レビューに使用する。
---

# 第三者検証

1. 検証対象の要求、Issue、受け入れ条件、diff範囲を確定する。不明なら実装者へ確認し、推測した完了条件でPASSを出さない。
2. 利用中のAgentが提供するサブエージェント機構を使い、実装を担当していない新しいコンテキストのverifierを起動する。
3. verifierへ要求とdiff範囲を渡し、 [`references/verifier.md`](./references/verifier.md)を完全に読んで従うよう指示する。
4. verifierの判定と根拠をそのまま報告する。FAILの場合は修正方針を提示し、非自明な修正は承認を得てから再検証する。

`check`は機械検証、`verify`は独立コンテキストによる第三者レビューであり、相互に代替しない。非自明な変更は両方を通す。

## 観点分割(任意の強化。#107)

大きい変更や見落としのコストが高い変更では、単体verifierの代わりに**観点別ファンアウト**を使ってよい。検証基準の正典は変わらず[`references/verifier.md`](./references/verifier.md)であり、各観点はその基準を担当範囲へ深掘りする分担にすぎない。

観点(5つ固定):

1. **要求とdiffの整合**: 要求・受け入れ条件とdiffの1対1突き合わせ、完了偽装パターン全般。
2. **Swift 6並行性とSendable**: actor境界、`@unchecked Sendable`の正当化、キュー・ロックの排他根拠。
3. **失敗系とfail-closed**: エラーの握りつぶし、無言の欠落、fail-closed不変条件の維持。
4. **docs・コード・テストの整合**: 同一PR内の一致(AGENTS.mdの不変条件)、テストの弱体化・空撃ち。
5. **domain-pitfalls・ハード制約**: `docs/domain-pitfalls.md`の既知の罠、private API、ネットワーク送信、Packagesの純度。

手順: 各観点が独立に指摘を出す → **指摘ごとに反証専任の再検証**(その指摘を一次情報で潰せるか試す)→ 反証できなかった指摘だけを生存として報告する。

判定規則: 指摘はseverity(blocking = 完了条件を満たさない / minor = 記録すべき観察)を持つ。**blockingの生存指摘(未再検証の超過分を含む)が1件でもあればFAIL。** minorだけならPASSとし、観察として全件報告する(単体verifierの「PASS + 軽微な観察」と同じ運用)。**5観点すべてが完走していることがPASSの前提**で、観点の検証が失敗・未完走の場合はFAILよりも優先して検証不成立(PASSでもFAILでもない)とし、未完走の観点を明示する ―― 検証しきれていない状態で確定判定を出さない。

オーケストレーション(G-0010 決定1・2):

- **目的**: 観点の分担で見落としを減らし、反証の再検証で誤検知を減らす。
- **エージェント数の上限**: 1回の起動で最大15体(観点5体 + 再検証は指摘ごとに1体・最大10体)。指摘が10件を超えた場合、超過分は再検証せず「未再検証の指摘」として全件報告する(無言で切り捨てない)。
- **停止条件**: 各観点・各再検証は1回で打ち切り、再試行しない。ループしない。
- Workflow機構を持つAgentは製品別アダプター側のスクリプト(Claude Codeは`.claude/workflows/verify.js`)で起動する。**Workflow機構を持たないAgent(codex / github-copilot / 未登録のfallback)は、同じ5観点を逐次に当て、同一の判定規則・報告形式を満たす。**

単体verifier(上記2.)と観点分割のどちらを使ったかは、検証報告に明記する。

## 設計レビュー(実装前の計画への敵対的検証。G-0012)

設計判断を含む変更では、plan-execute-verifyの計画(4項目入り)を人間の承認前に設計レビューへかける。基準の正典は[`references/design-reviewer.md`](./references/design-reviewer.md)。

1. **同系reviewer(必須層)**: 実装を担当していない新鮮なコンテキストを、主導Agentの機構で起動する ―― claude-code: verifierサブエージェントまたはfresh `claude -p` / codex: 新規`codex exec` / github-copilot: fresh session。未登録fallbackはfresh contextを作れる機構がある場合のみ成立し、**同一コンテキストで基準を逐次適用しても「同系独立レビュー完了」と記録しない**。
2. **異種reviewer(外部reviewer。追加層)**: `scripts/design-review.sh --stage design`で起動する。設定は`local/agent-review.json`(任意。形式・語彙の正典は`.agents/agent-review.schema.json`、記入例は`.agents/agent-review.example.json`)。設定が無ければ自動探索・自動起動せず`NOT_CONFIGURED`、利用不能なら理由を記録して続行する(`DEGRADED`)。**別Agentへの黙ったfallbackはしない。** 設定済みprofileでは`runtime`と`diversity`(runtime-only / model-family / runtime-and-model-family)を必須とし、弱い保証を無意識に選ばせない。**FULL**は「profileで明示した多様性レベルを満たし、reviewerが正常完了した」こと、**DEGRADED**は「設定なし・利用不能・要求した多様性を確認できなかった」ことを意味する。runtime-onlyはruntime差のみの保証であり、**「異種モデルreviewer」という語はmodel系レベルを実際に満たした場合に限って使う**。要求レベルと成立レベルの両方を記録する。
3. 両reviewerは**独立実行**する(相互の結果を渡さない)。入力(計画全文・Issue・プロンプト・出力schema)は同一にする。
4. 判定は4分類(READY / REVISE / DECISION_NEEDED / INCONCLUSIVE)。実行状態(COMPLETED / NOT_CONFIGURED / UNAVAILABLE / DIVERSITY_UNSATISFIED)とは別概念で、**判定はreviewerが正常実行され有効な出力を返した場合だけ記録する**(認証失敗や使用量超過をINCONCLUSIVEと呼ばない)。
5. 主導Agentは全指摘を省略せず、指摘ごとに採用 / 反証(一次情報付き) / 人間へ委譲を記録して統合する。判定が割れたら人間が裁定する。そのうえで通常どおり人間が計画を承認する。

**失敗の意味論**: 同系は必須層でありfail-closed ―― 起動失敗・出力不成立ならレビュー不成立として人間へ提示し、承認へ進めない(続行には人間の明示的waiverの記録 ―― 対象・理由・日付 ―― を要する)。fail-open(DEGRADED続行)は追加層の異種reviewerに限る。全体のレビュー範囲は異種まで完了でFULL、それ以外はDEGRADEDとして人間へ提示する。

**tool制限の製品差**: claude-code-cli / github-copilot-cliは可視tool集合と実行許可の2層で読取専用を保証する。codex-cliはtool allowlistを持たないため、designはread-only sandbox+実行ログの事後確認、implは使い捨てworktree+起動前後のsnapshot比較で同等の最終保証を作る(実装は`scripts/design-review.sh`)。webやMCPなど機械的に隠せないtoolは「利用不能」と主張せず、プロンプトで禁止しtool logで違反を検出したらreview不成立として扱う。

**記録要件**(レビュー完了時点で**即時**にIssueへ保存する。事後追補を通常運用にしない): 固定したレビュー入力全文 / reviewerごとの生出力 / runtime・CLI version・要求モデルと解決モデル・要求effort(解決値が確認可能なら併記) / 所要時間・トークン(取得可能なもの) / reviewer findings数とdistinct findings数の併記 / 指摘ごとの処置 / 人間裁定・waiverの内容。解決モデルが確認できない場合は`unconfirmed`と記録し、**要求値で代用しない**(model系レベルの要求は満たしたと数えない。runtime-onlyのみruntime差だけで成立する)。要求した多様性レベルと実際に成立したレベル(recordの`establishedDiversity`)を残す。

オーケストレーション(G-0010 決定1・2): **目的** = 実装前に設計欠陥を検出し手戻りを減らす(同系)+ 盲点の非相関(異種)。**上限** = 1回の設計レビューでreviewer最大2体(同系1+異種1)。統合は主導Agentが行う。**停止条件** = 各reviewerは1回で打ち切り、自動再試行・reviewer間の議論を行わない。

## レビューのclosure(設計・実装共通。G-0012)

blocking指摘を反映した「最後に変更された版」を独立確認せずに完了と呼ばない。設計・実装の両段階へ次の共通規則を適用する。

1. **対象の固定**: 各roundの開始前にレビュー対象を固定する ―― 設計は計画の版または内容hash、実装はHEAD・tracked diff・untracked manifestを含むsnapshot。同じroundの全reviewerは同一の固定snapshotを確認する。
2. **判定の失効**: blocking対応などで対象を変更した場合、変更前snapshotに対するREADY / PASSは変更後snapshotへ引き継がない(指摘がどの層由来かを問わない)。過去の判定は監査記録として残すが、最終版の合格判定には使わない。
3. **closure round**: 変更後のsnapshotを改めて固定し、fresh contextで再確認する。参加層 ―― 設計: 同系reviewerは必須、異種reviewerが設定済み・利用可能なら同じsnapshotを確認する。実装: 同系verifierは必須、高リスク領域では異種verifierも同じsnapshotを確認する。異種の利用不能は従来どおりDEGRADED開示で続行できる。
4. **blockingの処置**: 正常実行したreviewerのblockingは「修正して変更後snapshotで再確認」「一次情報による反証」「人間へ委譲して明示的waiverを記録」のいずれかへ必ず分類する。**未処置または未再確認のblockingが残る状態を完了と呼ばない。**
5. **round上限**: closure roundは設計・実装の各段階で最大2回(初回レビューは含めない)。各reviewerは1roundにつき1回だけ起動し、自動再試行・reviewer間の議論を行わない。トークン・時間は記録するが停止条件には使わない(runtime間で比較できないため。停止条件の正典はround数)。
6. **上限到達時の人間裁定**: 2回のclosure roundで収束しない場合、主導Agentだけで終端せず人間へ裁定を求める。選択肢 ―― 追加のclosure review / 残存リスクを受け入れてwaiver記録 / 変更の縮小・分割 / 計画・実装方針の見直し。裁定記録には対象snapshot・残っている指摘・実施round数と使用量・提示した選択肢・裁定結果・判断理由と日付を含める。

## 実装後検証への異種verifierの追加(高リスク領域のみ。G-0012)

実装後の同系verifier(上記)は全非自明変更で必須のまま変わらない。次の高リスク領域に触れる変更では、追加で異種verifierを`scripts/design-review.sh --stage impl`により起動する: **セキュリティ境界・Agent hook・並行性・TCC・データ移行**。判定規則は現行どおり(未反証のblocking指摘があればFAIL、要求が曖昧ならINCONCLUSIVE)で、実行状態・記録要件・失敗の意味論は設計レビューと同じ。implの記録には実装verifierの生出力と、例示・手動検証の実際の出力値を含める。
