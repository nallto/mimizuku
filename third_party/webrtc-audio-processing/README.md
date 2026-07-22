# webrtc-audio-processing(帰属表示)

本アプリは WebRTC の audio_processing モジュール(AEC3 ほか)を静的リンクで利用する(ADR-0013)。

- 入手元: <https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing>(freedesktop 配布)
- バージョン: v2.1(コミット `846fe90a289f58b7c9303a635142aa2c7caa93e5` にピン留め)
- ライセンス: BSD-3-Clause([COPYING](./COPYING))+ 特許許諾([PATENTS](./PATENTS))
- ソース取得とビルドは `scripts/build-webrtc-apm.sh`(成果物はコミットしない)

このディレクトリのファイルは上記コミットからコピーした原文であり、配布物(アプリバンドル・リリースノート)にも同梱する(公開時の整備は S20)。静的リンクされる依存成分(abseil / rnnoise / pffft / Ooura fft)のライセンスは [`third_party/README.md`](../README.md) を参照。
