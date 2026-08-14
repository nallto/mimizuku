# HTML説明のデザインシステム

このファイルは、説明HTMLに共通する視覚言語と出力契約の正典である。図種固有の配置は`types/`の選択したreferenceを併用する。

参考: [diagram-design at a5e3978](https://github.com/cathrynlavery/diagram-design/tree/a5e3978088cf89c7caff5c20cabd99fbc2a301de)。図種ごとの文法、複雑度予算、単一の視覚言語、出力前検査という考え方を採り入れ、Mimizukuの安全要件とコード説明用途に合わせて再設計している。上流のtemplateやcodeは複製しない。

## 情報設計

ページは次の順序に固定する。

1. eyebrow、結論を表す見出し、2行以内の要約
2. 主図1つ
3. 異なる問いへ答える場合だけ補助図を最大3つ
4. 根拠一覧
5. 推定・未確認点
6. 変更モードだけ変更補足

最初のviewportで結論と主図の開始位置まで見えるようにする。説明文をnodeへ詰め込まず、nodeは名前と短い補助ラベルに限定する。詳細は図の下へ置く。

## 共通予算

| 対象              | 上限                                  |
| ----------------- | ------------------------------------- |
| 主図              | 1                                     |
| 補助図            | 3。各図は異なる問いへ答える           |
| 図の合計          | 4                                     |
| node              | 9                                     |
| edge              | 12                                    |
| focal node / edge | 合計2                                 |
| node名            | 24文字を目安、最大2行                 |
| edge label        | 16文字を目安                          |
| evidence item     | 8。超える場合は代表根拠と残件数を示す |

上限を超える場合はoverviewとdetailへ分割する。同じHTML内でも、各図は独立した問いへ答え、見出しかnoteへ問いを明記する。

## 視覚トークン

templateのCSS custom propertiesを正典とし、生成物へ任意の色を増やさない。

| role            | 既定値    | 用途                      |
| --------------- | --------- | ------------------------- |
| `paper`         | `#f1f4f6` | ページ背景                |
| `surface`       | `#fbfdff` | nodeとevidenceの背景      |
| `surface-muted` | `#e5ebef` | context領域の背景         |
| `ink`           | `#202b38` | 見出し、主要stroke        |
| `muted`         | `#526273` | 補助説明、通常edge        |
| `soft`          | `#738395` | 二次的なラベル            |
| `rule`          | `#c5d0d8` | hairline、zone境界        |
| `accent`        | `#b84e68` | 変更点や主経路。最大2箇所 |
| `accent-soft`   | `#f6e2e8` | 変更点や主題の背景        |
| `runtime`       | `#23705f` | runtimeで観測した根拠     |
| `runtime-soft`  | `#ddf0ea` | runtime根拠の背景         |
| `inferred`      | `#84651c` | 推定・未確認              |
| `inferred-soft` | `#f3ecd9` | 推定・未確認の背景        |
| `link`          | `#315f9b` | evidenceへの参照          |

色だけへ意味を持たせず、`[変更]`、`runtime`、`未確認`などの短いtext labelを併記する。

## Typographyと余白

- 本文とnode名はsystem sansを使い、日本語を14px未満にしない。
- code、symbol、file path、edge labelだけsystem monoを使う。
- titleを含む全テキストにsystem sansを使い、明朝体・serifを使わない。
- titleはdesktopで2行以内を目安にし、44pxを上限にする。`h1`直下の文言を意味の切れ目ごとに`<span class="title-phrase">`へ分け、各phraseは390px幅へ収まる全角13文字程度を上限の目安にする。助詞を直前の語だけへ残さず、係る語句を同じphraseに含める。`h1`はflexでphrase間だけを折り返し、`text-wrap: wrap`、`line-break: strict`を使う。技術的な詳細や長い識別子はledeへ移し、`overflow-wrap: anywhere`で語中を強制分割しない。
- ledeは`width: 100%; max-width: none`でpage headerの利用可能幅全体へ広げ、`text-wrap: wrap`で通常の行送りにする。browserが行長を再配分する`text-wrap: pretty`や`balance`をpage headerへ使わない。
- 本文line-heightは1.65、図中labelは1.35以上にする。
- 座標、寸法、gap、paddingは4px gridへ揃える。
- node間は最低24px、diagram外周は最低32px確保する。
- node textは左右16pxのpadding内へ収める。mono labelが18文字を超える場合は短縮またはnodeを拡幅し、node名は必要なら2つの`<text>`へ分ける。box境界で文字を切らない。
- shadow、gradient、glass effect、pillの乱用を禁止する。境界はhairlineで示す。

## SVG共通規則

- `viewBox="0 0 1000 620"`を既定にし、必要なら高さだけ4px単位で増やす。
- `<svg class="explain-diagram">`へ`role="img"`と`aria-labelledby`を付ける。
- `<title>`を最初の子、続けて`<desc>`を置く。IDは図ごとに一意にする。
- nodeへ`class="diagram-node"`、edgeへ`class="diagram-edge"`を付ける。焦点には`is-focal`も付ける。
- 図種固有のnode、edge、zone、laneへ、選択した`types/` referenceのclassと`data-*`を付ける。これらは装飾用ではなくvalidatorが予算と文法を検査する契約である。
- edgeを先、nodeを後に描き、線がboxを横切って見えないようにする。
- 同じxまたはyにないnode間は直角connectorを使う。斜め線を使わない。
- 複数edgeで経路を共有しない。接続点を12px以上離す。
- edge labelは線から8px以上離し、必要なら`paper`色のmaskを置く。
- 凡例は主図内へ浮かせず、図の下端かHTML本文へ置く。

## HTML共通規則

- templateのheader、`.diagram-panel`、`.evidence-list`、`.unknowns`という大枠を維持する。変更モードではfooter直前の`.change-appendix`も維持する。通常の複数列`.evidence-card`と、変更説明用の全幅カードを用途別に残す。
- `main[data-explanation-mode]`は変更説明なら`change`、既存設計の説明なら`design`にする。
- `.evidence-list`は1列の全幅gridにし、各`.evidence-row`へ`.evidence-card`と同じ`surface`背景、`rule`枠線、6px角丸、20px余白を与える。種別、項目名、説明はカード内で上から順に置き、長文へ十分な横幅を使う。1列、全幅、余白、背景、枠線、角丸は任意の追加selectorで崩れない不変propertyとして扱う。
- `.change-appendix`の冒頭には直接の子として`<p class="section-label">Change appendix</p>`を置く。「一般的な変更確認」「変更確認の補足」などの追加カテゴリ見出しは置かない。`.change-files`、`.diff-overview`、`.diff-details`、`.verification-results`をこの順で置き、それぞれの`h2`を「変更ファイル」「差分概要」「重要な差分」「検証結果」にする。各sectionは`.evidence-card`と同じ視覚スタイルを持つ1列の全幅カードとし、内容に`.change-file-list`、`.diff-summary`、`.diff-excerpt`、`.verification-list`を含める。重要hunkは理解に必要な短い範囲へ絞り、全diffは明示要求がある場合だけ載せる。
- template内の汎用サンプルを一次情報へ置き換え、`data-template-sample="1"`を削除する。validatorはこの属性の残存を拒否する。
- light固定のeditorial paletteを使い、OS themeで配色を反転しない。
- 外部font、外部image、script、animationを使わない。inline `style`属性、CSS comment、CSS escapeを使わない。`!important`は`.evidence-list`、`.evidence-row`、`.change-section`の不変propertyを固定する正典宣言だけに限定し、追加CSSでは使わない。CSS selectorにattribute selector、ID selector、pseudo class / elementを追加しない。`:root`だけは色token定義のために使用できる。
- CSPはtemplateの6 directiveをexact allowlistとして維持し、directiveやsourceを追加しない。`on*` event属性とscheme付きURLも使わない。
- 画面幅が狭い場合はSVGを縮小して文字を潰さず、`.diagram-scroll`で横スクロールさせる。本文は`overflow-wrap: anywhere`でviewport内に収める。見出しは狭い画面でも`.title-phrase`の境界だけで折り返し、phrase内を分割しない。390px幅でphraseが収まらない場合はphrase自体を短くする。
- templateの共通CSSは削除・置換せず、図種固有のclassだけを追加する。OS theme分岐、shadow、gradientを追加しない。
- printでは背景色に意味を依存せず、borderとlabelが残るようにする。
- 動的文字列をHTML entityへescapeする安全要件は`SKILL.md`に従う。

## 出力前taste gate

- この図がparagraphや3列tableより理解しやすいか。
- 複数図がそれぞれ異なる問いへ答えているか。
- 主役が1つの問いに絞られているか。
- nodeを1つ削除または統合できないか。
- edgeを1つ削除しても関係が明白ではないか。
- accentが2箇所以下か。
- labelが線やboxと重なっていないか。
- node内の最長textがboxの左右paddingを越えていないか。
- 100%表示で本文とnode名を無理なく読めるか。
- 390px幅では主図が横スクロールし、本文が画面からはみ出さないか。
- `scripts/validate_html.py`がgreenか。
