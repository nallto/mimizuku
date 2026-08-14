# Call Tree

entry pointから対象symbolまでの静的な到達経路、または一つのsymbolから主要な呼び出し先を説明するときに使う。

## 文法

- rootを左または上へ置き、深さ方向を一方向へ固定する。
- nodeは`Type.symbol()`を主名、fileを短い補助labelにする。
- protocol dispatch、closure、notification、task、framework callbackは通常callと異なるedge styleとlabelで示す。
- 変更nodeへ`[変更]`、未実装nodeへ`[予定]`を付ける。

## 予算

- depth 5、node 9、branch 3、edge 12、focal 2まで。

## 機械検査契約

- 全nodeへ一意な`data-node-id`と`data-depth="0..5"`を付ける。root以外には`data-parent="親nodeのid"`も付ける。
- rootはdepth 0で1個にする。validatorはdepth、親の存在、親ごとのbranch上限を検査する。

## 必須label

- 非直列edge: `protocol`、`callback`、`Task`、`notification`など。
- 推定edge: `推定`と理由。

## SVG骨格

```svg
<path class="diagram-edge" d="M 260 180 H 360 V 300 H 440" />
<g class="diagram-node is-context" data-node-id="root" data-depth="0">…entry point…</g>
<g class="diagram-node is-focal" data-node-id="target" data-depth="1" data-parent="root">…対象symbol…</g>
```

branchは親nodeの異なる接続点から出し、循環はnodeを複製せず`↺`付きedge labelで示す。

## 失敗例

- runtime evidenceなしでcall stackと呼ぶ。
- production call siteを読まず、定義の参照だけで到達可能と断定する。
- 同じsymbolを複数箇所へ複製して循環を隠す。
