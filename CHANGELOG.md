# Changelog

## [0.1.1](https://github.com/nallto/mimizuku/compare/v0.1.0...v0.1.1) (2026-08-29)


### Features

* AEC 同期層と時刻付き捕捉ストリームを追加(AEC-2) ([#68](https://github.com/nallto/mimizuku/issues/68)) ([2d70f39](https://github.com/nallto/mimizuku/commit/2d70f39e5a2f86f257852281c2145e1ea66d4a95))
* AEC診断経路を追加し回り込み抑制の原因を計測可能にする ([#96](https://github.com/nallto/mimizuku/issues/96)) ([e760087](https://github.com/nallto/mimizuku/commit/e760087d890f7a3fa19b1580a8f48e7d0ba24f7f))
* **app:** Slice 0 の App ターゲットを XcodeGen で構成 ([#6](https://github.com/nallto/mimizuku/issues/6)) ([ad30e77](https://github.com/nallto/mimizuku/commit/ad30e77d5491c51f329458a9d7997812fefe2478))
* explain-codeスキルを追加 ([#103](https://github.com/nallto/mimizuku/issues/103)) ([01c34ef](https://github.com/nallto/mimizuku/commit/01c34eff1b422b0d4f850e7b3707fb2d4d5f8301))
* patrolスキルを追加して定期巡回を運用する ([#125](https://github.com/nallto/mimizuku/issues/125)) ([ed0b580](https://github.com/nallto/mimizuku/commit/ed0b580385660d4d506c0796b1498c39c2cf4261))
* verifyスキルへ観点別ファンアウトを追加する ([#123](https://github.com/nallto/mimizuku/issues/123)) ([19d6848](https://github.com/nallto/mimizuku/commit/19d6848f91b3fdf066a1495eb6ca589518bf91e8))
* WebRTC AEC3 のベンダリングとオフライン検証 CLI を追加(AEC-1) ([#67](https://github.com/nallto/mimizuku/issues/67)) ([9b92fff](https://github.com/nallto/mimizuku/commit/9b92fffdd1000775316ca2f7a8d593b6a3abc726))
* セッション録音 + AudioRouter + メニューバー状態表示(S2) ([#55](https://github.com/nallto/mimizuku/issues/55)) ([644b0b4](https://github.com/nallto/mimizuku/commit/644b0b40bce9167a831113c5418fc22dd5296440))
* デュアルストリーム捕捉と権限診断を実装(S4) ([#65](https://github.com/nallto/mimizuku/issues/65)) ([1ac1e8a](https://github.com/nallto/mimizuku/commit/1ac1e8a11a596f38281dea9b70505c1b89c2aa39))
* マイク→ライブ文字起こしを実装(S1、薄い端から端まで) ([#24](https://github.com/nallto/mimizuku/issues/24)) ([1b8cd36](https://github.com/nallto/mimizuku/commit/1b8cd3699b48495e1ff09f8580f591870f909523))
* マイク単体モードの隠し参照 tap で AEC を効かせる(AEC-4) ([#73](https://github.com/nallto/mimizuku/issues/73)) ([f801292](https://github.com/nallto/mimizuku/commit/f8012926c206964e8c04a719cc27c22adbf91a24))
* メインウィンドウ3ペイン骨格を追加する ([#100](https://github.com/nallto/mimizuku/issues/100)) ([b8eb594](https://github.com/nallto/mimizuku/commit/b8eb59466ffa82a3cf887e5091d7694dd63dd6e3))
* 両方モードで AEC3 をライブ適用する(AEC-3) ([#72](https://github.com/nallto/mimizuku/issues/72)) ([e9feb35](https://github.com/nallto/mimizuku/commit/e9feb35c855fdf656584cadb0ae1cc7f60b80af1))
* 文字起こし永続化とセッションモデルを追加 ([#94](https://github.com/nallto/mimizuku/issues/94)) ([86c5be0](https://github.com/nallto/mimizuku/commit/86c5be0edbe9d16734a287925707468336927ce4))
* 設計レビューと外部reviewer基盤をplan-execute-verifyへ正式導入する ([#140](https://github.com/nallto/mimizuku/issues/140)) ([f6cddc3](https://github.com/nallto/mimizuku/commit/f6cddc3786c129f981ef8100f610870da3b60d7c))


### Bug Fixes

* AEC処理済みマイクだけを正式音源にする ([#84](https://github.com/nallto/mimizuku/issues/84)) ([e70b978](https://github.com/nallto/mimizuku/commit/e70b9782624820bbacf9fbd522f4c02418ccddad))
* AEC参照なし時の遅延と状態遷移を修正 ([#74](https://github.com/nallto/mimizuku/issues/74)) ([#83](https://github.com/nallto/mimizuku/issues/83)) ([2a447a5](https://github.com/nallto/mimizuku/commit/2a447a51cf36bbd1c1d0a6c3fea0b9205c59cc6a))
* AEC復旧時にrender drift診断をepoch単位でリセットする ([#90](https://github.com/nallto/mimizuku/issues/90)) ([8590ffd](https://github.com/nallto/mimizuku/commit/8590ffd83e58387c589f9ee6dcd61af40b191ce7))
* docsビルドをPR checkで実行しdocsツリー外リンクを修正する ([#127](https://github.com/nallto/mimizuku/issues/127)) ([cc7c331](https://github.com/nallto/mimizuku/commit/cc7c331035cc7df8cdf225d8dc14a5f37aafebb2))
* protect-command hookのgit push誤検知をトークン単位判定で解消する ([#133](https://github.com/nallto/mimizuku/issues/133)) ([ba299e2](https://github.com/nallto/mimizuku/commit/ba299e2d1f6e8301213c0992e808cbc318540f4e))
* release-please PRのAIマージを拒否 ([#136](https://github.com/nallto/mimizuku/issues/136)) ([2e81310](https://github.com/nallto/mimizuku/commit/2e813104e597eeaf28b3748b1609aaf73d661b84))
* マイク捕捉の停止を検知してソース内部で再構築する ([#117](https://github.com/nallto/mimizuku/issues/117)) ([166be15](https://github.com/nallto/mimizuku/commit/166be154f0cf61b91620bfc93acf613ed09e3b45))
* 報告キューの時刻を実クロック由来に固定し推定記入を禁止する ([#138](https://github.com/nallto/mimizuku/issues/138)) ([3d00fd4](https://github.com/nallto/mimizuku/commit/3d00fd4f30bf4de962252e4475ca5abcab987eda))
* 捕捉の欠落区間を実測長の無音で埋めて時間軸を保つ ([#121](https://github.com/nallto/mimizuku/issues/121)) ([90476ea](https://github.com/nallto/mimizuku/commit/90476ea5ffadc0fa6300fcdab6e2a3efac73523a))

## Changelog

このファイルは release-please が Conventional Commits(PR タイトル)から自動生成・更新します。手で編集しないでください。
