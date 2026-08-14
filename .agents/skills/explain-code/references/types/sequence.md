# Sequence

時間順、async、callback、actor hop、request/responseを説明するときに使う。runtime traceがなければ「静的に構成したsequence」と明記する。

## 文法

- actorを上部へ横並びにし、時間を上から下へ流す。
- sync callは実線、returnは破線、fire-and-forgetは破線とopen markerで区別する。
- actor hopやqueue切替はedge labelへ明記する。
- branchは`alt`、任意処理は`opt`、反復は`loop`のframeで囲む。

## 予算

- lifeline 6、message 12、fragment 1、fragment nesting 1、focal message 2まで。6 lifelineを超える場合はownerを統合するかoverviewとdetailへ分割する。

## 機械検査契約

- lifelineは`sequence-lifeline`、fragmentは`sequence-fragment`をclassへ付ける。既存互換として`lifeline`、`frame`、`sequence-frame`も同じ数に含む。
- fragmentは入れ子にしない。validatorは個数とnestingを検査する。

## 必須label

- message: method、event、resultの短い名前
- branch: guardまたは失敗条件
- runtime未確認の順序: `未計測`または`順序不定`

## SVG骨格

```svg
<line class="sequence-lifeline" x1="180" y1="120" x2="180" y2="560" />
<path class="diagram-edge" d="M 180 220 H 420" />
<g class="diagram-node">…actor header…</g>
```

lifelineとmessageは時間順、actor headerは最後に描く。returnとasyncには追加classを付け、type referenceの線種へ対応させる。

## 失敗例

- 時間を逆向きにする上向きmessage。
- asyncをsync returnとして描く。
- 静的解析だけでruntime call stackと呼ぶ。
- 長いコード断片をmessageへ置く。
