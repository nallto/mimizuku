---
name: patrol
description: 定期巡回の内容を定義する。open PRのCI監視とmain追従、依存更新の可否判定、乖離検査、次タスクの下調べ、カバレッジ計測を無人境界の中で行うときに使用する。
---

# 定期巡回

承認者が応答できない時間帯に、承認を必要としない作業を進める巡回の手順(G-0010 決定3、追跡は#109)。**無人実行の境界(許可・禁止・着手範囲・変更確認・draft PR)は[`docs/development.md`の「無人実行と報告キュー」](../../../docs/development.md#無人実行と報告キュー)が正典**であり、本スキルはその境界の中で何を巡回するかだけを定義する。

実行間隔・稼働時間帯の登録と扱い(ローカル登録・リポジトリへ焼き込まない・時間帯を限定しない)は同節に従う。

## 巡回項目(この順に1パス)

1. **報告キューの棚卸し**: `report-queue`スキルに従い、pendingの最優先1件を報告する。`status: reported`のまま残っている項目は判断が済んだか確認し、済んでいれば削除する。
2. **mainの健全性**: mainの最新CIがgreenかを確認する。redならP1としてキューへ積む(P1は即時報告対象)。
3. **open PRのCI監視**: 全open PRのchecksを確認する。lint・fmt崩れなど機械的な失敗は修正してpushする(1件のPRにつき修正は1回まで。解決しなければP2)。設計判断が要る失敗は修正せずP2でキューへ。**bot管理のブランチ(dependabot・release-please)は修正対象外**(項目4の注意と同じ ―― botが上書きする)。
4. **open PRのmain追従**: mainが進んで古くなったPRブランチに、**コンフリクトが無い場合のみ**mainをブランチへマージしてpushし、CIを回し直す。コンフリクトは解決せずP2でキューへ。**rebaseは使わない** ―― 追従後のrebaseはforce pushを要し、無人実行では禁止(G-0010)かつ共通hookが拒否する。squash merge運用ではブランチ上のマージコミットは履歴に残らない。**bot管理のブランチ(dependabot・release-please)へは手動pushしない** ―― botが自ブランチをforce pushで上書きするため手動追従は消える。dependabotの追従が必要な場合は、`@dependabot rebase`コメントの投稿を**提案としてキューへ積む**(コメント投稿の実行は利用者判断 ―― 無人の許可範囲はdocs/development.mdの許可行に限る)。
5. **依存更新PRの確認**: dependabot等の更新PRの内容(changelog・影響範囲・CI結果)を確認し、可否判定をP2でキューへ積む。**マージはしない。**
6. **docs・コード・テストの乖離検査**: 直近のマージでdocs・コード・テストが同じPRで一致しているか(AGENTS.mdの不変条件)を点検する。乖離は修正せずIssue起票の提案としてP3へ(提案は`report-queue`スキルの優先度表でP3。乖離の修正自体が非自明な変更になりうるため)。
7. **リポジトリ衛生**: マージ済みで残ったリモートブランチ、放置されたworktree(`local/worktrees/`。項目9の常設worktree`local/worktrees/143-coverage-patrol/`は除く)、長期放置のneeds-human PR・Issueを検出し、P3で**報告のみ**行う。削除・クローズはしない(ブランチ削除は無人禁止)。
8. **次タスクの下調べ**: 着手候補が未調査なら`investigate-issues`(Issue群)または`slice-prep`(スライス)を実行する。結果の扱いは各スキルの定義に従う。
9. **カバレッジ計測**(G-0013 決定4・5): 前回の計測から7日未満なら何もしない。それ以外は下記「カバレッジ計測の手順」で`just coverage`を1回だけ実行し、結果を報告キューの単一の`coverage`項目へ反映する。計測の失敗は報告するだけで、他の項目は止めない。

## 停止条件と上限(G-0010 決定1・6)

- **目的**: 利用者不在の時間に、承認を要さない監視・追従・下調べを進め、判断材料をキューへ揃える。
- **停止条件**: 1巡回 = 各項目1パスで打ち切り、再試行しない(項目3の修正も1回まで)。巡回中に新たな非自明な変更の着手判断が必要になったら、着手せず計画案をキューへ積んで停止する(G-0010 決定6)。
- **エージェント数の上限**: 巡回自体は逐次手順で追加エージェントを使わない。**1巡回で起動するWorkflowは項目8の1つまで**とし、そのWorkflowは自身のSKILL.mdの上限に従う。
- **項目9の目的と停止条件**: 目的はsensor出力(G-0013 決定2)を人へ届け、テスト追加の着手判断の材料にすること。1巡回で`just coverage`を最大1回・再試行なしで打ち切る。sensor出力がゼロでも項目は残し、7日ごとの計測を続ける(G-0013 決定5)。追加エージェントは使わない。
- **項目9を無人で実行できるAgent**: コマンドに上限があり、上限超過を検知して停止できるAgent(現状はClaude Code)に限る。そうでないAgentは、人が見ている手動巡回のときだけ項目9を実行し、無人の巡回ではスキップする。
- 巡回での作業は`local/worktrees/`で行い、利用者のmain checkoutを占有しない(同節の作業場所規則)。

## カバレッジ計測の手順(項目9)

パスはすべてメインチェックアウトのルート(`<main-root>`)基準で解決する。`<path>` = `<main-root>/local/worktrees/143-coverage-patrol`(常設のdetached worktree。docs/development.mdの例外)、状態の置き場所は`<main-root>/local/cache/coverage-patrol/`(無ければ`mkdir -p`で作る。無くても作り直せるキャッシュ)。

1. **前回時刻**: `last-run`にepoch秒を1行で置く。無い・読めない・数値でない・未来の時刻なら「計測する」側へ倒す。7日未満ならここで終える。
2. **worktree**: `git fetch origin`が失敗したら計測失敗(計測未実行)。成功したら次の順で判定する。
   - `<path>`が無く、`git worktree list --porcelain`にも登録が無い → `git worktree add --detach <path> origin/main`で作る。
   - `<path>`が無いのに登録だけ残っている(prunable)→ 何もせず計測失敗(計測未実行。「`git worktree prune`が必要(人の操作)」と書く)。
   - `<path>`があり、`git worktree list --porcelain`に`worktree <path>`の行があり、かつ`git -C <path> rev-parse --show-toplevel`が`<path>`と一致する → `git -C <path> status --porcelain`が空のときだけ`git -C <path> checkout --detach origin/main`で最新へ移す。空でなければ触らずに計測失敗(計測未実行)。
   - `<path>`があるが上の条件を満たさない(未登録の残骸など)→ **何もせず**計測失敗(計測未実行)。`git -C <path>`が親のメインチェックアウトを操作するのを防ぐため。
3. **計測**: `<log>` = `mktemp <main-root>/local/cache/coverage-patrol/run-XXXXXXXX`が作ったファイル(この計測専用。失敗したら計測失敗(計測未実行))。直前に`git -C <path> rev-parse HEAD`を記録し、`<path>`で`just coverage > <log> 2>&1`をforegroundで実行する(上限10分を指定)。上限内に終わらずAgentがコマンドをbackgroundへ移した場合(Claude Codeは上限到達時に停止せず移す)は、待たずにそのタスクを停止して上限超過とする。終了コードを記録する。直後に、HEADが記録した値と一致し`git -C <path> status --porcelain`が空であることを確かめる(違えば、計測中に別の巡回がworktreeを動かしたとみなし計測失敗)。
4. **判定**: 根拠は手順2の成否、手順3の終了コード・上限超過の有無・HEADの確認、この計測の`<log>`の`summary:`行と`set point reached`行**だけ**。ほかのログは読まない。
   - 終了コード0、`summary:`行がちょうど1行、`uncovered_functions`か`wontcover_expired`が1以上 → **提案**(`kind: proposal`)。
   - 終了コード0、`summary:`行がちょうど1行、`uncovered_functions=0`・`wontcover_expired=0`、`set point reached`行あり → **到達**(`kind: reached`)。
   - それ以外(上記のどれかが欠ける、数値が読めない、手順2・3の失敗)→ **計測失敗**(`kind: failure`)。到達や提案として扱わない(fail-closed)。
5. **報告キューへの反映**(優先度はすべてP3。本文は3行以内で、詳細は`related`に書いたログを参照させる。提案・到達は`<main-root>/local/cache/coverage-patrol/last-result.log`、手順3を実行した計測失敗は同じ場所の`last-failure.log`。手順3より前の失敗(計測未実行)では`related`にログを書かない ―― 前回のログを今回の証拠にしないため):
   - 対象は、ファイル名が`^[0-9]{8}-[0-9]{6}-coverage-[0-9]{4}\.md$`に一致し、`status: pending`の項目だけ。`status: reported`の項目は報告した側のセッションのものなので、読むだけで変更も削除もしない。
   - 項目のfrontmatterに、`report-queue`の欄に加えて`kind`(proposal / reached / failure)と`result-at`(その結果を得た計測の時刻。`created`・`updated`と同じく`date +%Y-%m-%dT%H:%M:%S%z`の実行結果を使う)を書く。分類は`kind`だけで行う(本文から推測しない)。`kind`が無い・値が不正な項目は項目9のものとみなさず、集約・置き換え・削除の対象にしない(触らない)。
   - pendingが2件以上あれば、今回の結果を反映する前に1件へ集約する。提案・到達があればその中で`result-at`が最も新しい1件(提案・到達同士は結果の時刻で比べる)、無ければ計測失敗の中で`created`が最も古い1件を残し、残りのpendingを削除する(有効な結果を失敗で消さない)。
   - **提案・到達**: pendingの項目があれば本文・`kind`・`result-at`・`related`(`last-result.log`)を置き換え、`updated`を記録する(`created`は変えない)。無ければ新しいpendingの項目を作る。到達は、pendingもreportedのcoverage項目も無いときは作らない(G-0013 決定5)。
   - **計測失敗**: pendingの項目が計測失敗なら本文・`result-at`・`related`を置き換え(手順3を実行した失敗なら`last-failure.log`、計測未実行なら`related`のログを消す)、`updated`を記録する。pendingの項目が提案・到達なら本文の要点と`related`は置き換えず、本文の末尾に「直近の計測(<時刻>)は失敗: <理由>」を1行だけ書いて(既にあれば置き換えて)`updated`を記録する。`result-at`は変えない。pendingが無ければ新しい計測失敗の項目を作る。
   - 本文の書き方: 提案は「未カバーN関数 / M region、失効K件(失効があれば台帳の更新が必要 ―― 人間承認のPR)」「未カバー行(TSV)の多いファイル上位5件。着手はIssueの起票または既存Issue(例: #145)で、人間の承認後。reportedのcoverage項目が残っていれば、判断済みなら削除してよい」の2行。到達は「set point到達」の1行。計測失敗は理由と、手順3を実行した場合だけ終了コード(手順3より前の失敗は「計測未実行」と書く)。
6. **後始末**: 報告キューへの反映が**終わった後**に`last-run`を書く(途中で落ちたら次回に再計測する)。手順3で`<log>`を作った場合だけ、結果が提案・到達なら`last-result.log`へ、計測失敗なら`last-failure.log`へ`mv`で置き換える(人が読むためのログ。判定には使わない)。作っていなければどちらのログも変えない。`run-*`で更新から1日以上たったもの(落ちた巡回の残り)は削除する。

台帳・テスト・floorは無人で変更しない(G-0013 決定3・4・6)。提案は報告キューへの積み込みに限り、draft PRとIssueコメントは作らない(G-0013 決定4)。

既知の限界: 報告キューの確認と書き換えの間に別のセッションや同時に走った巡回が同じ項目を変更すると(ロックが無いため)、reportedの項目を書き換えたり、新しい結果が次回の計測まで届かなかったりしうる。影響はP3情報の遅れに限られ、次回の計測でpendingの項目が書き直される(reportedの項目は報告した側が判断のあとに消す)ので受け入れている(#143の裁定記録)。

## 結果の扱い

- すべての報告は`report-queue`スキルに従いキューへ積み、1ターン1件で報告する(P1のみ即時)。
- 恒久的に残す価値のある判明事実は、キューへ積む前にIssue・docs・ADRへ書く(AGENTS.md「知識の置き場所」)。
- 巡回で行った操作(push・PR更新・キュー追加)は、次に利用者が読む報告で漏れなく追跡できるようにする。禁止操作を行わないことの確認は、この操作記録を根拠にする。
