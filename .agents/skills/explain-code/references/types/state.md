# State Machine

event、guard、timeout、recoveryによる状態遷移を説明するときに使う。

## 文法

- startはfilled dot、endはring、stateは角丸長方形で示す。
- transition labelは`event [guard] / action`から必要な部分だけ使う。
- dominant flowを左から右、または上から下へ揃える。
- `any state → error`は全stateから線を引かず、注記としてまとめる。

## 予算

- state 8、transition 12、self-loop 2、focal state 1まで。

## 機械検査契約

- 開始markerへ`state-start`、終了markerへ`state-end`、自己遷移edgeへ`state-self-loop`を付ける。
- 開始と終了は各1個にし、主題stateだけを`diagram-node is-focal`にする。validatorはmarker数、self-loop、focal stateを検査する。

## 必須label

- transition: event。guardがある場合は省略しない。
- terminal failure: recovery可能か不可逆か。

## SVG骨格

```svg
<circle class="state-start" cx="100" cy="300" r="8" />
<path class="diagram-edge" d="M 108 300 H 220" />
<g class="diagram-node">…state…</g>
<g class="state-end">…outer ringとinner dot…</g>
```

transitionはedgeとして数え、start/end markerはnode予算へ含めない。

## 失敗例

- transitionが無label。
- UI flagとdomain stateを同じstateとして混ぜる。
- 実装に存在しない中間stateを事実として追加する。
