# Data Flow

値、event、audio buffer、model、fileがどこで生成・変換・保存・消費されるかを説明するときに使う。

## 文法

- source、transform、store、sinkを形またはtagで区別する。
- edge labelはデータ名または形式にし、method名は必要な場合だけ補助表示する。
- control flowを同じ図へ混ぜない。必要ならsequenceを補助図にする。
- device外へ出ない、永続化されないなど重要な境界は明示する。

## 予算

- node 9、edge 12、store 3、fan-out 3、focal 2まで。

## 機械検査契約

- 全nodeへ`data-source`、`data-transform`、`data-store`、`data-sink`、`data-fanout`のいずれか一つを付ける。兼務は問いに不可欠な場合だけ複数付与する。
- validatorはstoreとfan-outの上限、およびroleなしnodeを検査する。

## 必須label

- edge: data type、format、またはownership transfer
- store: 永続／一時、保存先の抽象名
- boundary: process、device、moduleなど問いに関係するもの

## SVG骨格

```svg
<path class="diagram-edge" d="M 240 300 H 400" />
<g class="diagram-node is-context data-source">…source…</g>
<g class="diagram-node is-focal data-transform">…transform…</g>
<g class="diagram-node data-store">…store…</g>
```

node tagへ`SOURCE`、`TRANSFORM`、`STORE`、`SINK`を付け、edge labelへデータ名を書く。

## 失敗例

- method callとdata flowを同じ矢印で表す。
- edgeへ長いpayload例を載せる。
- data ownerとcopyの存在を区別しない。
