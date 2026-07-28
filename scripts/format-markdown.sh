#!/usr/bin/env bash
# Git管理対象と未追跡のプロジェクト所有MarkdownだけをPrettierで整形・検査する。
set -euo pipefail

mode="${1:-}"
case "$mode" in
  --write | --check) ;;
  *)
    echo "usage: $0 --write|--check" >&2
    exit 2
    ;;
esac

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

markdown_files=()
while IFS= read -r -d '' file; do
  markdown_files+=("$file")
done < <(git ls-files --cached --others --exclude-standard -z -- '*.md')

if [[ ${#markdown_files[@]} -eq 0 ]]; then
  exit 0
fi

mise exec -- prettier "$mode" --ignore-path .prettierignore -- "${markdown_files[@]}"
