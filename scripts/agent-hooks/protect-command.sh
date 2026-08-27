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

# read -aはshellの引用符を解釈しないため、コマンド名・サブコマンド名を囲む単純な
# single / double quoteだけを外す。引用符の連結や展開を含む完全なbash parsingは行わない。
strip_outer_quotes() {
  local value=$1
  if ((${#value} >= 2)); then
    if [[ ${value:0:1} == "'" && ${value: -1} == "'" ]] ||
      [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
      value=${value:1:${#value}-2}
    fi
  fi
  printf '%s' "$value"
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
  local token_index
  for ((token_index = 0; token_index < ${#tokens[@]}; token_index++)); do
    tokens[token_index]=$(strip_outer_quotes "${tokens[token_index]}")
  done

  # `time git push` や `FOO=1 git push` を素通りさせないため、前置トークンを読み飛ばす。
  local start=0
  while ((start < ${#tokens[@]})); do
    case ${tokens[start]} in
      '!' | '{' | time | command | builtin | env | exec | nohup)
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

# AI AgentのPRマージは専用入口へ集約し、release-please管理PRだけを対象情報に基づいて
# 拒否する(G-0011)。このhookはtimeout時も決定的に動くようGitHubへ問い合わせず、
# 直接のGitHub CLI / API経路を拒否する。専用入口の内部プロセスはPreToolUse対象外である。
check_direct_merge_segment() {
  local -a tokens
  read -ra tokens <<<"$1" || return 0
  local token_index
  for ((token_index = 0; token_index < ${#tokens[@]}; token_index++)); do
    tokens[token_index]=$(strip_outer_quotes "${tokens[token_index]}")
  done

  local start=0
  while ((start < ${#tokens[@]})); do
    case ${tokens[start]} in
      '!' | '{' | time | command | builtin | env | exec | nohup)
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
  [[ ${tokens[start]} == gh || ${tokens[start]} == */gh ]] || return 0

  # ghの継承フラグを読み飛ばし、サブコマンドを特定する。
  local i=$((start + 1)) t
  while ((i < ${#tokens[@]})); do
    t=${tokens[i]}
    case $t in
      -R | --repo | --hostname)
        i=$((i + 2))
        ;;
      -R?* | --repo=* | --hostname=*)
        i=$((i + 1))
        ;;
      *)
        break
        ;;
    esac
  done
  ((i < ${#tokens[@]})) || return 0

  if [[ ${tokens[i]} == pr ]] && ((i + 1 < ${#tokens[@]})) && [[ ${tokens[i + 1]} == merge ]]; then
    deny "AI Agentはgh pr mergeを直接実行せず、scripts/agent-merge-pr.shを使うこと(G-0011)"
  fi

  [[ ${tokens[i]} == api ]] || return 0

  # RESTのPR merge endpointはHTTP methodや引数位置にかかわらず拒否する。
  # API引数の本文にコマンド例があっても誤検知しないよう、endpoint位置だけを検査する。
  local endpoint=
  local j=$((i + 1))
  while ((j < ${#tokens[@]})); do
    t=${tokens[j]}
    case $t in
      -X | --method | -H | --header | -F | --field | -f | --raw-field | -q | --jq | -t | --template | --hostname | -p | --preview | --cache | --input)
        j=$((j + 2))
        ;;
      -X* | --method=* | -H* | --header=* | -F* | --field=* | -f* | --raw-field=* | -q* | --jq=* | -t* | --template=* | --hostname=* | -p* | --preview=* | --cache=* | --input=*)
        j=$((j + 1))
        ;;
      --paginate | --slurp | --silent | --verbose | --include | --allow-escape-sequences)
        j=$((j + 1))
        ;;
      *)
        endpoint=$t
        break
        ;;
    esac
  done
  endpoint=${endpoint#\"}
  endpoint=${endpoint%\"}
  endpoint=${endpoint#\'}
  endpoint=${endpoint%\'}

  if [[ $endpoint =~ ^/?repos/[^/]+/[^/]+/pulls/[0-9]+/merge([?].*)?$ ]]; then
    deny "AI AgentはREST APIからPRを直接マージせず、scripts/agent-merge-pr.shを使うこと(G-0011)"
  fi

  # GraphQLは既知のmerge / auto-merge / merge queue mutation名を拒否する。
  if [[ $endpoint == graphql && $1 =~ (mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest) ]]; then
    deny "AI AgentはGraphQLからPRのmerge・auto-merge・merge queue操作を行わないこと(G-0011)"
  fi
  return 0
}

# `;` `&` `|`(`&&` `||`含む)・サブシェル・コマンド置換・改行を、引用符の外側だけで
# セグメント境界として扱う。本文やrgの検索語にある区切り文字をコマンドと誤認しない。
split_command_segments() {
  local text=$1
  local segment=
  local quote=
  local escaped=0
  local index char

  for ((index = 0; index < ${#text}; index++)); do
    char=${text:index:1}

    if ((escaped)); then
      segment+=$char
      escaped=0
      continue
    fi

    if [[ $quote != "'" && $char == $'\\' ]]; then
      segment+=$char
      escaped=1
      continue
    fi

    if [[ -n $quote ]]; then
      segment+=$char
      [[ $char == "$quote" ]] && quote=
      continue
    fi

    if [[ $char == "'" || $char == '"' ]]; then
      quote=$char
      segment+=$char
      continue
    fi

    case $char in
      ';' | '&' | '|' | '(' | ')' | '`' | $'\n')
        printf '%s\n' "$segment"
        segment=
        ;;
      *)
        segment+=$char
        ;;
    esac
  done
  printf '%s\n' "$segment"
}

# `$()`とbacktickはdouble quote内でも実行される。single quote内の同じ文字列は実行されないため
# 除外し、実行される内側のコマンドだけを再帰的に検査する。
check_embedded_commands() {
  local text=$1
  local quote=
  local escaped=0
  local index char next

  for ((index = 0; index < ${#text}; index++)); do
    char=${text:index:1}

    if ((escaped)); then
      escaped=0
      continue
    fi
    if [[ $quote != "'" && $char == $'\\' ]]; then
      escaped=1
      continue
    fi
    if [[ $char == "'" ]]; then
      if [[ -z $quote ]]; then
        quote="'"
      elif [[ $quote == "'" ]]; then
        quote=
      fi
      continue
    fi
    if [[ $char == '"' ]]; then
      if [[ -z $quote ]]; then
        quote='"'
      elif [[ $quote == '"' ]]; then
        quote=
      fi
      continue
    fi
    [[ $quote == "'" ]] && continue

    next=
    ((index + 1 < ${#text})) && next=${text:index+1:1}
    if [[ $char == '$' && $next == '(' ]]; then
      local start=$((index + 2))
      local depth=1
      local inner_quote=
      local inner_escaped=0
      local cursor inner_char inner_next
      for ((cursor = start; cursor < ${#text}; cursor++)); do
        inner_char=${text:cursor:1}
        if ((inner_escaped)); then
          inner_escaped=0
          continue
        fi
        if [[ $inner_quote != "'" && $inner_char == $'\\' ]]; then
          inner_escaped=1
          continue
        fi
        if [[ $inner_char == "'" ]]; then
          if [[ -z $inner_quote ]]; then
            inner_quote="'"
          elif [[ $inner_quote == "'" ]]; then
            inner_quote=
          fi
          continue
        fi
        if [[ $inner_char == '"' ]]; then
          if [[ -z $inner_quote ]]; then
            inner_quote='"'
          elif [[ $inner_quote == '"' ]]; then
            inner_quote=
          fi
          continue
        fi
        [[ -n $inner_quote ]] && continue

        inner_next=
        ((cursor + 1 < ${#text})) && inner_next=${text:cursor+1:1}
        if [[ $inner_char == '$' && $inner_next == '(' ]]; then
          depth=$((depth + 1))
          cursor=$((cursor + 1))
          continue
        fi
        if [[ $inner_char == ')' ]]; then
          depth=$((depth - 1))
          if ((depth == 0)); then
            check_command_text "${text:start:cursor-start}"
            index=$cursor
            break
          fi
        fi
      done
      continue
    fi

    if [[ $char == '`' ]]; then
      local backtick_start=$((index + 1))
      local backtick_escaped=0
      local backtick_cursor backtick_char
      for ((backtick_cursor = backtick_start; backtick_cursor < ${#text}; backtick_cursor++)); do
        backtick_char=${text:backtick_cursor:1}
        if ((backtick_escaped)); then
          backtick_escaped=0
          continue
        fi
        if [[ $backtick_char == $'\\' ]]; then
          backtick_escaped=1
          continue
        fi
        if [[ $backtick_char == '`' ]]; then
          check_command_text "${text:backtick_start:backtick_cursor-backtick_start}"
          index=$backtick_cursor
          break
        fi
      done
    fi
  done
}

check_command_text() {
  local command_text=${1//$'\\\n'/}
  local command_segment
  while IFS= read -r command_segment; do
    check_push_segment "$command_segment"
    check_direct_merge_segment "$command_segment"
  done < <(split_command_segments "$command_text")
  check_embedded_commands "$command_text"
}

# 行継続(`\`+改行)はコマンド区切りではないため、分割前にbashと同じ意味論で除去する
# (空白ではなく空文字。トークン中間の行継続 `pu\` + 改行 + `sh` も `push` に結合される)。
check_command_text "$cmd"

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
