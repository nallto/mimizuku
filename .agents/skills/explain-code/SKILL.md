---
name: explain-code
description: コード変更や既存設計を、diff、静的な呼び出し経路、実行・状態フロー、責務境界、必要に応じたHTMLで根拠付きに説明する。「変更を詳しく説明」「呼び出し経路で見せて」「設計を可視化」「HTMLで説明」など、利用者が詳細な可視化説明を求めたときに使用する。
---

# コードの可視化説明

説明対象を実コード上の位置と経路へ結び付け、人間が変更や設計の意味を追える形で示す。通常報告では自動適用せず、詳細な説明を求められたときだけ使用する。

## 1. モードを決める

- **変更モード**: diff、PR、commit、実装計画、現在の変更が対象なら選ぶ。変更されたsymbolを呼び出し経路、状態遷移、責務境界上で強調する。
- **設計モード**: 既存機能、アーキテクチャ、データフロー、特定処理の仕組みが対象なら選ぶ。entry pointから主要な境界と終端までを追う。
- 利用者がモードを指定した場合は指定を優先する。明示がなければ上記の対象から決め、両方が必要なら「現在の設計」と「変更後」を分ける。
- 実装前の計画は変更モードで扱うが、未実装部分を現行コードの事実として描かない。

## 2. 一次情報を集める

1. 対象の要求、Issue、diff範囲、機能名のうち利用可能なものを確定する。
2. 変更モードではdiffの全量、変更symbolの定義、production call site、関連テストとdocsを読む。
3. 設計モードではentry point、主要な呼び出し先、データ所有者、非同期境界、エラーまたは終了経路を読む。
4. 名前やディレクトリ構造だけで経路を断定しない。protocol dispatch、closure、notification、task、actor hop、framework callbackなど、静的な直列呼び出しにならない境界を確認する。

読み取りと説明を基本とし、製品コード、テスト、docsを変更しない。HTMLを求められた場合だけ後述のローカル成果物を作成できる。

## 3. 根拠レベルを付ける

経路の各edgeまたは重要な主張を、次のいずれかとして扱う。

- **静的確認**: 呼び出し、参照、型適合、登録処理をコードから確認できる。
- **runtime確認**: テスト結果、trace、log、計測結果など、実行時の一次情報で確認できる。
- **推定**: framework挙動、動的dispatch、未実装計画などに基づく推論である。推定理由と未確認点を書く。

「call stack」はruntime evidenceがある場合だけ使う。コード参照から構成したものは「静的call chain」「callback flow」「状態フロー」など、実態に合う名前にする。

skillやAgent設定を説明する場合、明示されたpathの`SKILL.md`を読んで実行できたことは「本文を利用可能」の確認に留める。自動探索、暗黙発火、slash command表示をruntime確認済みとするには、対象製品の新規sessionでその経路自体を観測する。

## 4. 必要なビューを組み合わせる

説明前に [`references/visual-patterns.md`](./references/visual-patterns.md) を読み、Architecture、Sequence、Flowchart、Data flow、State machine、Call tree、Swimlane、Change mapから利用者の主な問いへ直接答える主図を1種類選ぶ。選択後は同ファイルから案内される図種別referenceを完全に読む。

主図だけでは別の重要な軸を表現できない場合、異なる問いへ答える補助図を最大3つ追加できる。例えばChange mapで変更全体を示し、Sequenceで時間順、Data flowで値の移動、Call treeで到達経路を補う。各図の見出しかnoteへ、その図が答える問いを明記する。同じ関係を別の見た目で繰り返さず、短いparagraphやtableで十分なら図を追加しない。

変更モードでは、変更されたnodeを図中で明示する。変更前後を比較する場合は、同じ抽象度と用語を使う。

## 5. HTMLを必要な場合だけ作る

HTMLは、利用者が明示的に求めた場合、または3つ以上の関係・状態・境界を並べて比較しないと理解しにくい場合だけ作る。

1. [`references/html-design-system.md`](./references/html-design-system.md)と選択した図種別referenceを完全に読む。
2. [`assets/explanation-template.html`](./assets/explanation-template.html) を基礎にし、共通CSS、class、token、page構造を維持する。共通CSSを削除・置換せず、図種固有のclassだけを追加する。汎用サンプルを対象内容へ置き換え、`data-template-sample="1"`を削除する。diagramのSVG bodyは選択した図種の文法に合わせて置き換える。
   - `h1`の文言は意味の切れ目ごとに`<span class="title-phrase">`へ分ける。phrase内では改行されないため、各phraseを390px幅に収まる長さにし、技術的な詳細や長い識別子はledeへ移す。
   - 変更モードでは、根拠と非影響範囲を`.evidence-list`内の全幅`.evidence-row`で示す。各rowは`.evidence-card`と同じ背景、枠線、角丸、余白を持つ1列の全幅カードにする。これらの不変propertyはtemplateの限定的な優先指定を維持し、通常の複数列カード用classは比較や独立した小要素へ利用できる形で残す。
   - 変更モードでは`main`へ`data-explanation-mode="change"`を指定し、根拠と未確認点の後、footerの直前へ`.change-appendix`を置く。冒頭に`Change appendix`というsection labelを置き、変更ファイル、差分概要、重要な差分、検証結果をそれぞれ独立した全幅カードと`h2`にする。「一般的な変更確認」のような追加カテゴリは置かない。全diffは利用者が明示的に求めた場合だけ載せる。
   - 設計モードでは`main`へ`data-explanation-mode="design"`を指定する。変更補足は置かない。
3. `local/agent-artifacts/`がなければ作り、`local/agent-artifacts/explain-code-<短い識別子>.html`へ保存する。
4. 実データ、秘密情報、録音、文字起こしを埋め込まない。コード識別子と必要最小限の短い抜粋だけを使う。
5. 識別子、コード抜粋、Issue本文など一次情報から埋め込む文字列は、`&`、`<`、`>`、`"`、`'`をHTML entityへescapeし、markupとして解釈させない。信頼できない文字列を属性名、要素名、CSS、URLへ組み込まない。
6. 外部CDN、外部font、analytics、ネットワーク取得を追加しない。templateのContent Security Policyを維持し、script、object、form送信、外部取得を許可しない。単一ファイルで表示可能にする。
7. `python3 .agents/skills/explain-code/scripts/validate_html.py <生成HTML>`を実行し、errorをすべて解消する。
8. headless browserまたは利用可能なpreviewで1440px幅と390px幅を確認する。実レンダリングを確認できない場合は、その理由を未確認点として報告する。
9. 自動でブラウザを開かない。最終回答にローカルファイルへのリンクを付ける。
10. HTMLはgit管理へ追加せず、利用終了後に削除できるローカル成果物として扱う。

## 6. 説明を返す

次の順序を基本とし、不要な節は省く。

1. 結論を短く述べる。
2. 主図と、説明に必要な補助図で位置、経路、変化を示す。
3. 根拠となるfileとsymbolをクリック可能なローカルリンクで示す。
4. runtime確認済みの事実、静的確認、推定と未確認点を分ける。
5. 変更モードでは、変更ファイル、diff概要、重要差分、検証結果を最後に補足する。
6. HTMLを作成した場合は成果物へリンクする。

説明だけでは要求を満たせない欠落や不具合を発見しても、このskill内で修正へ拡張しない。発見事項と根拠を報告し、変更が必要なら別タスクとして扱う。
