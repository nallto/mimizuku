# Mimizuku タスクランナー。
# 原則: `just check` = CI。人間もエージェントもこれ一本で検証する。
# レシピ名(check / lint / fmt / fmt-check / test)は規約であり変更しない。
# 中身は macOS/Swift 固有。

set shell := ["bash", "-euo", "pipefail", "-c"]

# CI でテストするローカル SPM パッケージ(純ロジック・TCC 非依存)。
packages := "Packages/MimizukuCore"

default:
    @just --list

# CI と同一の検証一式(完了報告の前提条件)。
check: setup-check lint fmt-check test

# プレースホルダ・未設定マーカーの残存を検査。
setup-check:
    @bash scripts/setup-check.sh

# 全 Swift ソースを lint。
lint:
    @swiftlint lint --strict

# 全 Swift ソースをその場で整形。
fmt:
    @swiftformat .

# 書き込まずに整形を検査(CI 用)。
fmt-check:
    @swiftformat --lint .

# 純ロジックのパッケージテスト(TCC / 音声ハードウェア非依存。macos-26 CI で実行)。
# ハードウェア/権限依存のテストはローカル限定 ―― docs/domain-pitfalls.md を参照。
test:
    @for p in {{packages}}; do echo "== swift test: $p =="; swift test --package-path "$p"; done

# 単一ファイル整形。PostToolUse フック(.claude/hooks/post-edit.sh)が
# 編集のたびに自動で呼び出す。
fmt-file file:
    @swiftformat "{{file}}"

# App ビルド(Xcode プロジェクト作成後 = Slice 0 以降に有効)。.xcodeproj は
# 初回開発セッションで作るため、まだ `just check` には含めない。
# app-build:
#     xcodebuild -scheme Mimizuku -configuration Debug build
