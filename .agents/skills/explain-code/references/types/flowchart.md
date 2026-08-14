# Flowchart

条件分岐、validation、fallback、error handling、判断結果を説明するときに使う。

## 文法

- 開始から終了まで主方向を上から下へ固定する。
- processは角丸長方形、decisionはdiamond、terminalは短い角丸形で示す。
- decisionから出る全edgeへ条件または結果を付ける。
- error pathを右側、正常経路を中央へ置く。意味を色だけで区別しない。

## 予算

- process 7、decision 3、terminal 3、edge 12、focal 2まで。

## 機械検査契約

- 全nodeへ`flow-process`、`flow-decision`、`flow-terminal`のいずれか一つを付ける。
- decisionへ一意な`data-node-id`を付け、そこから出るedgeへ`decision-edge`、`data-from="decisionのid"`、空でない`data-label`を付ける。validatorは各decisionに2本以上のlabel付きedgeがあることを検査する。

## 必須label

- decision: yes/noではなく、可能なら具体的な結果を使う。
- error terminal: errorの伝播先または利用者に見える結果。

## SVG骨格

```svg
<path class="diagram-edge" d="M 500 180 V 236" />
<path class="diagram-edge decision-edge" data-from="valid" data-label="valid" d="M 580 300 H 720" />
<path class="diagram-edge decision-edge" data-from="valid" data-label="invalid" d="M 500 364 V 460" />
<g class="diagram-node flow-process">…process rect…</g>
<g class="diagram-node flow-decision" data-node-id="valid"><polygon class="node-box" points="500,236 580,300 500,364 420,300" />…decision…</g>
<g class="diagram-node flow-terminal">…terminal…</g>
```

decisionからのedge labelはdiamond外側の開いた領域へ置く。

## 失敗例

- branchを単なる縦並びのboxへする。
- decision edgeを無labelにする。
- happy pathだけ描いてfail-closedやcleanupを消す。
