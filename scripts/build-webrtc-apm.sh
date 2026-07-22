#!/usr/bin/env bash
# WebRTC audio_processing(AEC3)のベンダリングビルド(ADR-0013)。
#
# freedesktop 版 webrtc-audio-processing をピン留めコミットから取得し、
# arm64 静的ライブラリ + ヘッダを Vendor/webrtc-apm/ へ配置する。
# 成果物はコミットしない(gitignore)。abseil は meson の wrap(subproject)で
# 自己完結ビルドし、全静的ライブラリを 1 本(libwebrtc-apm-bundle.a)へ束ねて
# Xcode 側のリンク指定を単純に保つ。
#
# 再実行はスタンプ(ピン留めコミット)一致なら即終了する。CI はこのスクリプトの
# ハッシュをキーに Vendor/webrtc-apm をキャッシュする(.github/workflows/ci.yml)。
set -euo pipefail

REPO="https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git"
# v2.1(タグの指すコミットに直接ピン留め ―― タグの付け替えに追随しない)
PINNED_COMMIT="846fe90a289f58b7c9303a635142aa2c7caa93e5"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/webrtc-apm"
STAMP="$VENDOR/.stamp"
WORK="$ROOT/Vendor/_src/webrtc-audio-processing"
BUILD_DIR="$WORK/builddir"

# スタンプにはピンだけでなく本スクリプト自身のハッシュも含める
# (ビルドフラグ等の変更をローカルでも再ビルドとして検知するため)。
SCRIPT_HASH="$(shasum -a 256 "$0" | cut -d' ' -f1)"
STAMP_VALUE="$PINNED_COMMIT $SCRIPT_HASH"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" ]]; then
    echo "webrtc-apm: up to date ($PINNED_COMMIT)"
    exit 0
fi

echo "webrtc-apm: building $PINNED_COMMIT"

if [[ ! -d "$WORK/.git" ]]; then
    mkdir -p "$(dirname "$WORK")"
    git clone --no-checkout "$REPO" "$WORK"
fi
git -C "$WORK" fetch --quiet origin "$PINNED_COMMIT"
git -C "$WORK" checkout --quiet --force "$PINNED_COMMIT"

# abseil はシステム依存にせず meson の wrap fallback で subproject ビルドする。
# builddir はコミット固定(上の checkout --force)なので、存在すれば再利用する。
if [[ ! -d "$BUILD_DIR" ]]; then
    meson setup "$BUILD_DIR" "$WORK" \
        --buildtype=release \
        --default-library=static \
        --prefix="$VENDOR" \
        --libdir=lib \
        --wrap-mode=forcefallback
fi
ninja -C "$BUILD_DIR"

rm -rf "$VENDOR"
meson install -C "$BUILD_DIR" --quiet

# subproject(abseil)を含む全静的ライブラリを 1 本へ束ねる(リンク指定の単純化)。
# 注: macOS 標準 bash は 3.2(mapfile 非対応)のため while-read で集める。
mkdir -p "$VENDOR/lib"
STATIC_LIBS=()
while IFS= read -r lib; do
    STATIC_LIBS+=("$lib")
done < <(find "$BUILD_DIR" -name '*.a' | sort)
if [[ ${#STATIC_LIBS[@]} -eq 0 ]]; then
    echo "error: no static libraries produced" >&2
    exit 1
fi
libtool -static -o "$VENDOR/lib/libwebrtc-apm-bundle.a" "${STATIC_LIBS[@]}"

echo "$STAMP_VALUE" > "$STAMP"
echo "webrtc-apm: installed to $VENDOR"
