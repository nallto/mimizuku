# サードパーティ・ライセンス一覧(NOTICE)

本アプリに静的リンクされるサードパーティ成分と、そのライセンス原文の所在。配布物(アプリバンドル・リリースノート)にも同梱する(公開時の整備は S20)。ベンダリングの実体は `scripts/build-webrtc-apm.sh`(ADR-0013)。

| 成分 | ライセンス | 原文 |
|---|---|---|
| webrtc-audio-processing(WebRTC audio_processing / AEC3) | BSD-3-Clause + 特許許諾 | [COPYING](./webrtc-audio-processing/COPYING) / [PATENTS](./webrtc-audio-processing/PATENTS) |
| abseil-cpp(WebRTC の依存、wrap ビルド) | Apache-2.0 | [LICENSE](./abseil-cpp/LICENSE) |
| rnnoise(WebRTC 同梱、NS の一部) | BSD-3-Clause | [COPYING](./rnnoise/COPYING) |
| pffft(WebRTC 同梱、FFT) | FFTPACK 系(BSD 類似) | [LICENSE](./pffft/LICENSE) |
| Ooura fft(WebRTC 同梱、FFT) | 独自(要表示) | [LICENSE](./ooura-fft/LICENSE) |
