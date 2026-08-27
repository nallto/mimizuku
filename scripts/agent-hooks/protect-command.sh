#!/usr/bin/env bash
# Claude Code / Codex / GitHub Copilot共通のPreToolUseフック: 危険なshellコマンドをブロックする。
# exit 2 = ブロック(stderrがAgentへフィードバックされる)。
# 注意: settings.json の Bash deny ルールは前方一致で回避されうるため、ここが実質的な
#       防御線(多層防御の2層目)。文字列検査であり完全ではない。
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -z "$cmd" ]] && exit 0

deny() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# --- git push 系 ---
# コマンド全体への部分一致は PR 本文などの引数文字列まで誤検知する(#111)ため、
# 区切り文字でセグメントへ分割し、実際に git push を実行するセグメントの引数だけを検査する。
# 限界: bash を完全にはパースしない。クォート内の区切り文字でも分割する(過剰検査側に倒す)。
# `bash -c "…"` 経由・`env -i` などオプション付きラッパー・`-fu` のような結合フラグは
# 検出しない(1層目の権限設定と規律が受ける)。
# 既定ブランチ名は意図的にハードコード(動的解決は origin の無い fixture や hook の timeout で壊れる)。

# refspec(または `src:dst` の dst)が既定ブランチを指すか。
# `heads/main` は refspec DWIM で `refs/heads/main` に解決されるため含める。
is_default_branch_ref() {
  local ref=$1
  [[ $ref == *:* ]] && ref=${ref#*:}
  [[ $ref =~ ^((refs/)?heads/)?(main|master)$ ]]
}

check_push_segment() {
  local -a tokens
  read -ra tokens <<<"$1" || return 0

  # `time git push` や `FOO=1 git push` を素通りさせないため、前置トークンを読み飛ばす。
  local start=0
  while ((start < ${#tokens[@]})); do
    case ${tokens[start]} in
      '!' | time | command | builtin | env | exec | nohup)
        start=$((start + 1))
        ;;
      [A-Za-z_]*=*)
        start=$((start + 1))
        ;;
      *)
        break
        ;;
    esac
  done
  ((start < ${#tokens[@]})) || return 0
  [[ ${tokens[start]} == git || ${tokens[start]} == */git ]] || return 0

  # git のグローバルオプションを読み飛ばしてサブコマンドを特定する。
  local i=$((start + 1)) t
  while ((i < ${#tokens[@]})); do
    t=${tokens[i]}
    case $t in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path)
        i=$((i + 2))
        ;;
      -*)
        i=$((i + 1))
        ;;
      *)
        break
        ;;
    esac
  done
  ((i < ${#tokens[@]})) || return 0
  [[ ${tokens[i]} == push ]] || return 0

  for ((i = i + 1; i < ${#tokens[@]}; i++)); do
    t=${tokens[i]}
    case $t in
      --force* | -f)
        deny "force push は禁止(G-0001: squash 統一・履歴保護)"
        ;;
      +*)
        # `+refspec` は --force と同じ強制更新。
        deny "force push は禁止(G-0001: squash 統一・履歴保護)"
        ;;
      -*) ;;
      *)
        if is_default_branch_ref "$t"; then
          deny "main への直接 push は禁止。ブランチを作成し PR を出すこと(AGENTS.md)"
        fi
        ;;
    esac
  done
  return 0
}

# 行継続(`\`+改行)はコマンド区切りではないため、分割前に bash と同じ意味論で除去する
# (空白ではなく空文字。トークン中間の行継続 `pu\` + 改行 + `sh` も `push` に結合される)。
segments=${cmd//$'\\\n'/}
# `;` `&` `|`(`&&` `||` 含む)・サブシェル・コマンド置換・ブレースグループ・改行を
# セグメント境界として扱う。
for sep in ';' '&' '|' '(' ')' '{' '}' '`'; do
  segments=${segments//"$sep"/$'\n'}
done
while IFS= read -r segment; do
  check_push_segment "$segment"
done <<<"$segments"

# --- フック・検証の回避 ---
if [[ "$cmd" =~ --no-verify ]]; then
  deny "--no-verify によるフック回避は禁止(AGENTS.md)"
fi

# --- 広範囲の破壊的削除 ---
if [[ "$cmd" =~ rm[[:space:]]+-[a-zA-Z]*[rf][a-zA-Z]*[rf] ]]; then
  if [[ "$cmd" =~ rm[[:space:]]+-[a-zA-Z]+[[:space:]]+(/([[:space:]]|$)|~|\$HOME|\.\.) ]]; then
    deny "リポジトリ外・広範囲への rm -rf は禁止"
  fi
fi

exit 0
