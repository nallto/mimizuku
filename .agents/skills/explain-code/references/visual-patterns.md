# 可視化パターンの選択

最初に利用者の問いへ直接答える主図を1種類選ぶ。主図だけでは重要な別軸を表現できない場合、異なる問いへ答える補助図を最大3種類追加する。

## 選択表

| 利用者が知りたいこと | 主図 | 読むreference |
| --- | --- | --- |
| componentと責務境界 | Architecture | [`types/architecture.md`](./types/architecture.md) |
| async、callback、actor hopの時間順 | Sequence | [`types/sequence.md`](./types/sequence.md) |
| 条件分岐、error、fallback | Flowchart | [`types/flowchart.md`](./types/flowchart.md) |
| 値、event、fileの生成・変換・保存 | Data flow | [`types/data-flow.md`](./types/data-flow.md) |
| eventによる状態遷移 | State machine | [`types/state.md`](./types/state.md) |
| entry pointからsymbolへの到達経路 | Call tree | [`types/call-tree.md`](./types/call-tree.md) |
| owner間のhandoff | Swimlane | [`types/swimlane.md`](./types/swimlane.md) |
| diff、before/after、影響範囲 | Change map | [`types/change-map.md`](./types/change-map.md) |

HTMLを作る場合は、選択した図種のreferenceに加えて[`html-design-system.md`](./html-design-system.md)を読む。

## 選択規則

- method callとdata transferの両方がある場合、利用者の問いが「いつ」ならSequence、「何がどこへ」ならData flowを選ぶ。
- componentの配置が主題ならArchitecture、実行主体間のhandoffが主題ならSwimlaneを選ぶ。
- branchをSequenceへ押し込み過ぎず、判断条件自体が主題ならFlowchartへ切り替える。
- lifecycle全体を説明するならState machine、特定requestの一回の進行ならSequenceを選ぶ。
- 変更位置を見せるだけならChange map、変更されたsymbolへ実行が到達する理由を見せるならCall treeを選ぶ。
- 2種類以上が有効な場合もdominant axisを主図にする。補助図は時間順、値の移動、到達経路、状態遷移など、主図と異なる問いへ答える場合だけ追加する。
- 各図の見出しかnoteへ「何を確認する図か」を明記する。同じnodeとedgeを配置だけ変えて反復しない。
- 図は合計4つを上限とする。上限へ達しても情報を詰め込まず、残りはparagraph、table、または別資料へ分ける。

## HTMLを使わない条件

- 3列以下のtableで同じ関係を示せる。
- nodeが1つ、edgeが1つ以下である。
- 短いtext call chainだけで問いへ答えられる。
- 利用者が簡潔な報告だけを求めている。

## 変更と根拠の表示

- `[+]`は追加、`[~]`は変更、`[-]`は削除、`[予定]`は未実装を表す。
- runtime evidenceがない経路は「静的call chain」「静的に構成したsequence」などと呼ぶ。
- protocol dispatch、closure、notification、task、actor hop、framework callbackは通常callと異なるedge labelを付ける。
- 推定edgeは理由と未確認点を図外の根拠欄にも記載する。
- 変更モードでは、図と根拠の後へ変更ファイル一覧、diffstat、重要hunk、検証結果を補足する。全diffを本文の理解より先に置かない。
