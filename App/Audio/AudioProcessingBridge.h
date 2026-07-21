#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// WebRTC audio_processing(AEC3)の Obj-C++ ブリッジ(ADR-0013)。
///
/// Swift から C++ を直接触らないための境界。フォーマットは
/// 48kHz / モノラル / 10ms(= 480 サンプル)の int16 固定。
/// 有効: AEC3・High Pass Filter・Noise Suppression。無効: AGC・VAD。
///
/// 呼び出し順序(厳守): 各 10ms tick で
/// `processRenderFrame:`(far-end = システム音声)→ `processCaptureFrame:`(マイク)。
///
/// スレッド安全ではない。1 インスタンスを単一の処理系列(オフライン CLI /
/// ライブ統合の同期キュー)からのみ使うこと。
@interface AudioProcessingBridge : NSObject

/// 1 フレームのサンプル数(48kHz × 10ms)。
@property (class, nonatomic, readonly) NSInteger frameSampleCount;

/// APM を構成して利用可能にする。失敗時 NO。
- (BOOL)initializeProcessing;

/// far-end(システム音声)の 10ms フレームを供給する。`frame` は
/// `frameSampleCount` サンプルの int16 モノラル。
- (BOOL)processRenderFrame:(const int16_t *)frame;

/// near-end(マイク)の 10ms フレームを処理し、`frame` を処理後の音声で
/// 上書きする(in-place)。
- (BOOL)processCaptureFrame:(int16_t *)frame;

/// 内部状態を初期化する(デバイス変更・tap 再構築時)。フィルタは再収束する。
- (void)reset;

/// APM を解放する。以後の process 呼び出しは NO を返す。
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
