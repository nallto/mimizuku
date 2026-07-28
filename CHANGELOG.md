# Changelog

## [0.1.1](https://github.com/nallto/mimizuku/compare/v0.1.0...v0.1.1) (2026-07-28)


### Features

* AEC 同期層と時刻付き捕捉ストリームを追加(AEC-2) ([#68](https://github.com/nallto/mimizuku/issues/68)) ([b842226](https://github.com/nallto/mimizuku/commit/b842226aada2282b26781ee3887da10ea9b3468d))
* **app:** Slice 0 の App ターゲットを XcodeGen で構成 ([#6](https://github.com/nallto/mimizuku/issues/6)) ([e128dda](https://github.com/nallto/mimizuku/commit/e128dda3707c0bc509d02395e2cb52603bd0c3d2))
* WebRTC AEC3 のベンダリングとオフライン検証 CLI を追加(AEC-1) ([#67](https://github.com/nallto/mimizuku/issues/67)) ([d0b4361](https://github.com/nallto/mimizuku/commit/d0b4361508b50a32450793bf147f89993ae30276))
* セッション録音 + AudioRouter + メニューバー状態表示(S2) ([#55](https://github.com/nallto/mimizuku/issues/55)) ([51518e7](https://github.com/nallto/mimizuku/commit/51518e7ba9419965ebc09b7fafbc82c8b60ca434))
* デュアルストリーム捕捉と権限診断を実装(S4) ([#65](https://github.com/nallto/mimizuku/issues/65)) ([d5b463a](https://github.com/nallto/mimizuku/commit/d5b463a586605923f967d28ce5b37f2d6e6cc689))
* マイク→ライブ文字起こしを実装(S1、薄い端から端まで) ([#24](https://github.com/nallto/mimizuku/issues/24)) ([89d057f](https://github.com/nallto/mimizuku/commit/89d057ff3b6c9d19581f09bb036d8d6715b300b1))
* マイク単体モードの隠し参照 tap で AEC を効かせる(AEC-4) ([#73](https://github.com/nallto/mimizuku/issues/73)) ([4d802fa](https://github.com/nallto/mimizuku/commit/4d802fa433acf067d24dce632265cf2551d60409))
* 両方モードで AEC3 をライブ適用する(AEC-3) ([#72](https://github.com/nallto/mimizuku/issues/72)) ([00235c8](https://github.com/nallto/mimizuku/commit/00235c8fae1b0256644345b54a9f0a44e311eb56))


### Bug Fixes

* AEC処理済みマイクだけを正式音源にする ([#84](https://github.com/nallto/mimizuku/issues/84)) ([ba947a8](https://github.com/nallto/mimizuku/commit/ba947a80cbbd0fa8b63ef7b369b2b24667c136ad))
* AEC参照なし時の遅延と状態遷移を修正 ([#74](https://github.com/nallto/mimizuku/issues/74)) ([#83](https://github.com/nallto/mimizuku/issues/83)) ([e3ee51e](https://github.com/nallto/mimizuku/commit/e3ee51e5e01f99c6e506e5a4d341208da9d70aee))

## Changelog

このファイルは release-please が Conventional Commits(PR タイトル)から自動生成・更新します。手で編集しないでください。
