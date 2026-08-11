# ADR-0008: 3ペインUIは標準SwiftUI構成とし、activation policyを動的に切り替える

- ステータス: Accepted
- 日付: 2026-08-11
- 関連: #30(D3) / ADR-0005 / `docs/design/main-window.md` / S6

## Context(背景)

メインウィンドウは、セッションブラウザ、中央ワークスペース(波形+統合文字起こし)、inspector(要約・TODO・メモ・付帯情報)の3領域を持つ([`docs/design/main-window.md`](../design/main-window.md))。中央ワークスペースを主作業領域とし、幅が必要な場合はinspector、次にセッションブラウザの順で畳める必要がある。また[`docs/DESIGN.md`](../DESIGN.md)は、macOS標準のコンポーネント、メニュー、ショートカットを優先すると定める。

本アプリは`LSUIElement=true`のメニューバー常駐アプリ(ADR-0005)である。`.accessory`なactivation policyのままでは、`openWindow`で開いたウィンドウが前面化されない場合があり、主メニューバーも存在しないためEditメニューや標準ショートカットへ到達できない。3ペインの構成に加え、作業ウィンドウ表示中の前面化とメニュー到達性を決める必要がある。

### 3ペインの実現方式

- `NavigationSplitView`(sidebar + detail)+`.inspector`は採用する。セッション一覧と中央ワークスペースの関係、右側の派生情報というinspectorの意味論、標準Material、divider、トグル、キーボード到達性をSwiftUIの標準コンポーネントで表現できる。
- 3カラム`NavigationSplitView`は採用しない。content列は第2の選択リストを意図しており、中央の主作業領域と意味論が一致しない。
- `NSSplitViewController`による3ペイン管理は採用しない。`canCollapseFromWindowResize = true`を設定しても実機ではsidebarとinspectorが期待順に畳まれず、ウィンドウリサイズ時の補助ペインの連続的な幅再配分もSwiftUIペインと視覚的に一致しなかった。
- `HSplitView`の手組みは採用しない。標準コンポーネントが持つMaterial、divider、状態保存、キーボード操作を再実装する負担が大きい。

### 標準SwiftUI構成と自動折りたたみ

通常のSwiftUI `Window`は既定で[`WindowResizability.contentMinSize`](https://developer.apple.com/documentation/swiftui/windowresizability)を使い、表示中のペインが要求する最小サイズをウィンドウへ反映する。実機ではペインを自動では畳まず、inspectorを広げるとウィンドウの縮小停止幅も増え、狭い状態でinspectorのdividerを広げると外枠が拡大した。

この制約を回避する候補として、SwiftUIコンテンツを[`NSHostingView`](https://developer.apple.com/documentation/swiftui/nshostingview)で包み、公開APIの[`sizingOptions`](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions)を空にした上で、ウィンドウ内容幅を3段階へ分類してペイン表示を切り替える方式を実機検証した。この方式は自動折りたたみを実現できたが、標準SwiftUIだけでは不要なAppKitホスト、幅閾値、利用者の表示意図との合成、OS更新時の回帰確認が必要になる。

Mimizukuでは標準性と保守性を優先し、この独自レスポンシブ方式は採用しない。補助ペインはSwiftUIが提供するsidebarトグルと、`.inspector`のBindingへ接続したinspector用ツールバー項目で利用者が表示切替し、表示中の全ペインが最小幅へ達したらウィンドウの縮小を止める。自動的な折りたたみ順は保証しない。

### 前面化とメニューの方式

- `.accessory`のまま`NSApp.activate()`だけを呼ぶ方式は採用しない。主メニューバーを利用できず、DESIGN.mdの標準メニュー要件を満たさない。
- 作業ウィンドウ表示中だけ`.regular`へ切り替え、対象ウィンドウがすべて閉じたら`.accessory`へ戻す方式を採用する。作業中はDockアイコンと標準メニューを得て、常駐時はメニューバーアプリへ戻れる。
- 常時`.regular`とする方式は採用しない。Dockと⌘Tabへ常時表示され、ADR-0005で定めた製品の性格が変わる。

## Decision(決定)

1. 3領域は標準の`NavigationSplitView`(sidebar + detail)+`.inspector`で構成する。`Window`のコンテンツとして直接配置し、ペインのレイアウト、divider、表示状態はSwiftUIに所有させる。
2. `NSHostingView.sizingOptions = []`による柔軟ホスト、ウィンドウ幅の監視、幅閾値に基づく自動表示切替は実装しない。ウィンドウはSwiftUI既定のcontent minimum sizeを尊重し、必要な幅へ達したら縮小を止める。
3. sidebarはSwiftUIが提供する標準トグル、inspectorは`.inspector`のBindingへ接続したツールバー項目で表示切替する。中央の表示領域が不足する場合、利用者はinspector、sidebarの順で畳める。SwiftUIが将来標準の自動折りたたみを提供した場合も、独自閾値を追加せず標準挙動を優先する。
4. ペイン幅は単一のレイアウトメトリクスへ集約する。初期値はsidebarが`min 160 / ideal 240 / max 320`、中央が`min 480`で最大幅なし、inspectorが`min 240 / ideal 360 / max 600`とする。既定ウィンドウサイズは1200×680ptとする。
5. SwiftUIは環境やdivider操作に応じて指定と異なる実幅を選ぶ場合がある。UIテストは指定値への完全一致ではなく、各ペインが指定範囲を守り、中央が480pt未満へ圧縮されず、内容が画面外へ見切れないことを確認する。
6. sidebarとinspectorの表示状態は利用者の選択として保持し、再度ウィンドウを開いたときに復元する。具体的な保存機構はS6で選ぶが、幅監視から表示状態を書き戻す独自ロジックは追加しない。
7. activation policyは、作業ウィンドウを開く直前に`.regular`へ切り替えて`NSApp.activate()`を呼び、対象ウィンドウがすべて閉じたら`.accessory`へ戻す。`LSUIElement=true`は維持する。
8. S6では、標準トグル、表示状態の復元、最小幅、divider操作、前面化、最後の対象ウィンドウを閉じた後の`.accessory`復帰を検証する。TCCや音声ハードウェアは不要な範囲とする。

## Consequences(結果)

- sidebar、inspector、divider、Material、キーボード操作はSwiftUI標準の意味論と操作感を維持し、独自レイアウトコードとOS更新時の保守負担を抑えられる。
- ペイン表示中は、ウィンドウをコンテンツの最小幅より狭くできない。inspectorを広げた状態では縮小停止幅が増え、狭いウィンドウでinspectorを広げると外枠が拡大する場合がある。
- ウィンドウリサイズだけではinspectorとsidebarを自動的に畳まない。中央を広く使うには利用者が標準トグルで補助ペインを畳む必要があり、`docs/design/main-window.md`の中央優先と折りたたみ順は表示切替の操作順として実現する。
- 実際のS6画面内容で手動切替が重大な利用性問題になると確認された場合は、局所的な修正を重ねず、標準APIの変化も含めて新しいADRで再評価する。
- activation policyの切替と対象ウィンドウ数の監視はApp層に必要になる。OS更新の影響を受けるため実機確認を要する。

## 実機確認結果

2026-08-10から2026-08-11に、macOS 26のApple Silicon実機で確認した。

- 前面化と標準メニュー: MenuBarExtraから開いたウィンドウは前面かつkeyになり、`.regular`切替直後から主メニューと⌘C/⌘Vを利用できた。最後の対象ウィンドウを閉じると`.accessory`へ戻り、再度開いても動作した。Dockアイコンの出現・消滅は許容範囲だった。
- 標準SwiftUI構成: sidebarとinspectorは自動では畳まれず、inspector幅に応じてウィンドウの縮小停止幅が変わった。狭い状態でinspectorを広げると外枠が拡大した。一方、各ペインのdivider、標準sidebarトグル、`.inspector`のBindingによる表示切替はSwiftUI標準の操作感を維持した。
- `NSSplitViewController`: sidebarとinspectorはウィンドウ縮小で畳まれず、補助ペインの幅再配分がSwiftUI版と異なって不自然だった。
- 連続幅フィードバック: 高速リサイズ時のビジー、dividerの吸着、sidebarの意図しない拡大、ペインが畳まれない状態を確認した。
- 柔軟ホスト + 内側幅監視: ウィンドウは縮小できたが、sidebarとinspectorが同時に画面外へ見切れた。
- 柔軟ホスト + 外側3段階監視: 自動折りたたみと再表示を実現できたが、標準SwiftUI構成に対してAppKitホストと独自の状態合成が必要になったため採用しない。
- inspector幅の上限省略: `inspectorColumnWidth`の`max`を省略してdividerを限界まで拡大すると、SwiftUIが非有界に近いウィンドウ幅を`NSWindow`へ渡し`NSInternalInconsistencyException`で異常終了した。有限の`max`指定では再現しないため、inspectorの上限は必須とする。

比較スパイクは`local/spike-adr-0008/`に置き、各候補の失敗版も`experiments/`へ保存した。このディレクトリはコミットせず、S6実装へ必要な判断だけを本ADRに残す。
