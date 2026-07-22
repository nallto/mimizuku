#import "AudioProcessingBridge.h"

#include <modules/audio_processing/include/audio_processing.h>

// 48kHz / モノラル / 10ms 固定(ADR-0013)。
static const int kSampleRateHz = 48000;
static const int kChannels = 1;
static const int kFrameSamples = kSampleRateHz / 100; // 10ms = 480

// AEC3 は既定設定で使う。#61 のオフラインゲート(実録音 20260722-004003 の試聴)で
// 試した代替は、いずれも既定より劣った:
// - NS kHigh: ノイズ状残留は減るが、ダブルトーク時に自分の声が潰れる。
// - dominant nearend 判定の緩和(enr_threshold 0.5 / trigger_threshold 6 を
//   EchoControlFactory 自作で注入): 自分の声は残るがエコー抑圧が悪化。
// 再調整する場合は EchoControlFactory の自作が必要(freedesktop 版は
// EchoCanceller3Factory を配布しない)。

@implementation AudioProcessingBridge {
    webrtc::scoped_refptr<webrtc::AudioProcessing> _apm;
}

+ (NSInteger)frameSampleCount {
    return kFrameSamples;
}

- (BOOL)initializeProcessing {
    webrtc::scoped_refptr<webrtc::AudioProcessing> apm =
        webrtc::AudioProcessingBuilder().Create();
    if (!apm) {
        return NO;
    }

    // 有効: AEC3(mobile_mode = false が AEC3)・HPF・NS。無効: AGC・VAD(ADR-0013)。
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.high_pass_filter.enabled = true;
    config.noise_suppression.enabled = true;
    // kModerate: kHigh はダブルトーク時に自分の声まで潰した(#61 実測)。
    // ノイズ状の残留エコーは AEC3 側の nearend チューニングと合わせて調整する。
    config.noise_suppression.level =
        webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    apm->ApplyConfig(config);

    if (apm->Initialize() != webrtc::AudioProcessing::kNoError) {
        return NO;
    }
    _apm = apm;
    return YES;
}

- (BOOL)processRenderFrame:(const int16_t *)frame {
    if (!_apm) {
        return NO;
    }
    const webrtc::StreamConfig streamConfig(kSampleRateHz, kChannels);
    // render(far-end)は解析のみで書き換え不要だが、int16 API は出力先を要求する。
    int16_t scratch[kFrameSamples];
    return _apm->ProcessReverseStream(frame, streamConfig, streamConfig, scratch) ==
        webrtc::AudioProcessing::kNoError;
}

- (BOOL)processCaptureFrame:(int16_t *)frame {
    if (!_apm) {
        return NO;
    }
    // AEC3 は render/capture の相互相関で遅延を自動推定する。ここでの値は
    // 初期ヒントに過ぎない(0 = 揃っている前提から探索を始める)。
    _apm->set_stream_delay_ms(0);
    const webrtc::StreamConfig streamConfig(kSampleRateHz, kChannels);
    return _apm->ProcessStream(frame, streamConfig, streamConfig, frame) ==
        webrtc::AudioProcessing::kNoError;
}

- (void)reset {
    if (_apm) {
        _apm->Initialize();
    }
}

- (void)shutdown {
    _apm = nullptr;
}

@end
