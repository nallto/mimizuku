# Architecture

コンポーネント、module、service、frameworkとその責務境界を説明するときに使う。

## 文法

- 主方向を左から右、または上から下の一方へ固定する。
- 2つ以上のnodeを同じ所有境界へまとめる場合だけzoneを使う。
- 依存とdata flowが異なる場合は同じedgeへ重ねず、主題側だけを図示して他方を注記する。
- 外部systemとOS frameworkは境界外のnodeとして区別する。

## 予算

- node 9、edge 12、zone 3、focal 2まで。

## 機械検査契約

- 所有境界は`class="diagram-zone"`で表す。validatorはzone上限を検査する。
- `diagram-zone → diagram-edge → diagram-node`の順に記述する。全type共通でnode後のedgeと斜め直線を拒否する。

## 必須label

- zone: 所有者またはmodule名
- edge: 呼び出し、依存、転送のうち曖昧になるものだけ
- focal: `[変更]`または問いの中心である理由

## SVG骨格

```svg
<rect class="diagram-zone" x="40" y="80" width="360" height="420" />
<path class="diagram-edge" d="M 280 180 H 420" />
<g class="diagram-node is-context">…外部または入口…</g>
<g class="diagram-node is-focal">…中心component…</g>
```

zoneを使う場合のz-orderは`zone → edge → node`にする。

## 失敗例

- 全fileをnodeにする。
- すべてのboxを同じ見た目にする。
- zoneとswimlaneを混在させる。
- off-axisのnodeを斜め線で結ぶ。
