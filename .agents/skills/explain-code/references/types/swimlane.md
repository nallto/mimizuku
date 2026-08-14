# Swimlane

UI、App service、Package、OS、人間など複数の担当間で処理が受け渡されるときに使う。

## 文法

- laneは担当またはownershipで分け、file種類や時系列区間では分けない。
- flowは上から下へ進め、handoffだけlaneを横断する。
- actor hop、権限境界、外部操作をhandoff labelへ示す。
- 同じlane内の細かなcallは統合し、責務単位のstepにする。

## 予算

- lane 5、step 10、handoff 8、focal 2まで。

## 機械検査契約

- lane背景へ`swimlane`、step nodeへ`swim-step`、laneを横断するedgeへ`swim-handoff`を付ける。
- `swimlane → diagram-edge → diagram-node`の順に記述する。validatorはlane、step、handoffの上限を検査する。

## 必須label

- lane: ownerまたは実行主体
- handoff: request、result、dataの短い説明

## SVG骨格

```svg
<rect class="swimlane" x="40" y="80" width="280" height="500" />
<rect class="swimlane" x="320" y="80" width="280" height="500" />
<path class="diagram-edge swim-handoff" d="M 260 240 H 380" />
<g class="diagram-node swim-step">…責務単位のstep…</g>
```

lane背景を先、handoff edgeを次、step nodeを最後に描く。

## 失敗例

- laneごとに独立したflowとなり、handoffが見えない。
- architecture zoneをlaneとして並べるだけ。
- 一つのmethodごとにstepを作る。
