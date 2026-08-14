# Change Map

diffの変更位置、変更前後、影響するcall site・test・docsを一つの構造で説明するときに使う。

## 文法

- 中央に変更symbolまたは変更責務を置き、左に入口、右に影響先を置く。
- `[+]`、`[~]`、`[-]`、`[予定]`をtextで示す。
- before/after比較は同じnode配置と用語を保った2図にする。
- 直接変更と波及影響をedge styleで区別し、推定影響にはlabelを付ける。

## 予算

- changed node 5、context node 4、edge 12、before/after各9 nodeまで。

## 機械検査契約

- 直接変更したnodeへ`is-changed`、入口や既存構造のnodeへ`is-context`を付ける。`is-focal`は変更の中心を重ねて示すために使う。
- validatorはchanged nodeとcontext nodeの上限を検査する。

## 必須label

- changed node: 変更種別
- edge: `calls`、`reads`、`tests`、`documents`など影響の種類
- 未実装: `[予定]`

## SVG骨格

```svg
<path class="diagram-edge" d="M 260 300 H 420" />
<path class="diagram-edge is-focal" d="M 640 300 H 800" />
<g class="diagram-node is-context">…入口または既存構造…</g>
<g class="diagram-node is-focal is-changed">…変更責務…</g>
<g class="diagram-node">…影響先…</g>
```

列は`ENTRY / CHANGE / EFFECT`を基本にし、before/afterの場合は同じ座標系を2図で共有する。

## 失敗例

- file一覧を並べただけで変更の意味を示さない。
- beforeとafterで抽象度や配置が変わる。
- testやdocsをproduction flowのnodeとして混ぜる。
