# Mimizuku タスクランナー。
# 原則: `just check` = CI。人間もエージェントもこれ一本で検証する。
# レシピ名(check / lint / fmt / fmt-check / test)は規約であり変更しない。
# 中身は macOS/Swift中心で、文書の共通整形も含む。

set shell := ["bash", "-euo", "pipefail", "-c"]

# CI でテストするローカル SPM パッケージ(純ロジック・TCC 非依存)。
packages := "Packages/MimizukuCore"

default:
    @just --list

# CI と同一の検証一式(完了報告の前提条件)。
check: setup-check agent-config-check lint fmt-check test aec-diag-build

# プレースホルダ・未設定マーカーの残存を検査。
setup-check:
    @bash scripts/setup-check.sh

# Agent共通skill・環境別アダプター・危険コマンド防止hookを検証。
agent-config-check:
    @bash scripts/check-agent-config.sh
    @bash scripts/test-agent-config-check.sh

# 全 Swift ソースを lint。
lint:
    @swiftlint lint --strict

# Swiftとプロジェクト所有Markdownをその場で整形。
fmt:
    @swiftformat .
    @bash scripts/format-markdown.sh --write

# 書き込まずに整形を検査(CI 用)。
fmt-check:
    @swiftformat --lint .
    @bash scripts/format-markdown.sh --check

# 純ロジックのパッケージテスト(TCC / 音声ハードウェア非依存。macos-26 CI で実行)。
# ハードウェア/権限依存のテストはローカル限定 ―― docs/domain-pitfalls.md を参照。
test:
    @for p in {{packages}}; do echo "== swift test: $p =="; swift test --package-path "$p"; done

# 単一ファイル整形。Claude CodeのPostToolUseフック(.claude/hooks/post-edit.sh)が
# 編集のたびに自動で呼び出す。対象外の拡張子は何もしない。
fmt-file file:
    @case "{{file}}" in *.swift) swiftformat "{{file}}" ;; *.md) mise exec -- prettier --write --ignore-path .prettierignore -- "{{file}}" ;; esac

# Xcode プロジェクトを project.yml から生成(ADR-0004)。生成物 Mimizuku.xcodeproj /
# App/Info.plist はコミットしない ―― 開く/ビルドの前にこれを実行する。
generate:
    @xcodegen generate

# AEC 診断解析 CLI(#75 / ADR-0015)のビルド検査。swift test は executable target を
# ビルドしないため、check へ明示的に含める。
aec-diag-build:
    @swift build --package-path Packages/MimizukuCore --product aec-diag

# AEC 診断試行を解析する(#75)。使い方: just aec-diag ~/.local/state/mimizuku/aec-diagnostics/<trial>
aec-diag dir:
    @swift run --package-path Packages/MimizukuCore aec-diag "{{dir}}"

# WebRTC audio_processing(AEC3)のベンダリングビルド(ADR-0013)。
# ピン留めコミットと一致していれば即終了する。要 meson / ninja(mise.toml)。
vendor-apm:
    @bash scripts/build-webrtc-apm.sh

# App の署名付きローカルビルド(完全な Xcode 必須)。TCC プロンプトは署名済み
# ビルドでのみ出る(domain-pitfalls #4)ため、ローカルは通常署名でビルドする。
# Xcode 依存のため純ロジック検証の `just check` には含めない(CI は別ジョブ)。
app-build: vendor-apm generate
    @xcodebuild -project Mimizuku.xcodeproj -scheme Mimizuku -configuration Debug build
    @xcodebuild -project Mimizuku.xcodeproj -scheme aecprobe -configuration Debug build
