#!/usr/bin/env bash
# 異種reviewer(外部reviewer)の起動アダプター(G-0012)。reviewerの起動と記録だけを担い、
# 判定・統合は主導Agentが行う。同系reviewerは各Agentの機構で起動する(verify SKILL)。
#
# 使い方:
#   design-review.sh --stage design|impl --lead-runtime <runtime> --lead-family <family> \
#     --prompt-file <path> --output-schema <path> [--profile <name>] \
#     [--record-file <path>] [--artifact-dir <dir>]
#
# 設定は local/agent-review.json(無ければ NOT_CONFIGURED)。語彙・形式の正典は
# .agents/agent-review.schema.json。実行状態と理由は記録JSONへ必ず残し、異種の
# 利用不能では exit 0 で続行させる(fail-open + 開示。G-0012)。引数不正のみ exit 64。
set -euo pipefail

stage="" lead_runtime="" lead_family="" prompt_file="" out_schema=""
profile_name="" record_file="" artifact_dir=""

while (($#)); do
  [[ $# -ge 2 ]] || { echo "design-review.sh: 引数に値がない: $1" >&2; exit 64; }
  case $1 in
    --stage) stage=$2 ;;
    --lead-runtime) lead_runtime=$2 ;;
    --lead-family) lead_family=$2 ;;
    --prompt-file) prompt_file=$2 ;;
    --output-schema) out_schema=$2 ;;
    --profile) profile_name=$2 ;;
    --record-file) record_file=$2 ;;
    --artifact-dir) artifact_dir=$2 ;;
    *)
      echo "design-review.sh: 不明な引数: $1" >&2
      exit 64
      ;;
  esac
  shift 2
done

[[ $stage == "design" || $stage == "impl" ]] || { echo "--stage は design|impl" >&2; exit 64; }
[[ -n $lead_runtime && -n $lead_family ]] || { echo "--lead-runtime / --lead-family は必須" >&2; exit 64; }
[[ -n $prompt_file && -f $prompt_file ]] || { echo "--prompt-file が必要" >&2; exit 64; }
# 構造化出力を第一手段として保証するため必須(codex=--output-schema / claude=--json-schema。
# ネイティブ機構の無いcopilotはプロンプト指示+フェンス除去fallbackで受ける)。
[[ -n $out_schema && -f $out_schema ]] || { echo "--output-schema が必要" >&2; exit 64; }

root=$(git rev-parse --show-toplevel)
schema_file="$root/.agents/agent-review.schema.json"
config_file="$root/local/agent-review.json"
started_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
start_epoch=$(date +%s)

if [[ -z $artifact_dir ]]; then
  artifact_dir="$root/local/agent-artifacts/design-review/$(date +%Y%m%d-%H%M%S)-$stage"
fi
mkdir -p "$artifact_dir"
stdout_file="$artifact_dir/reviewer-stdout.log"
stderr_file="$artifact_dir/reviewer-stderr.log"
output_file="$artifact_dir/reviewer-output.json"

# --- 記録 ---------------------------------------------------------------
# state / reason / scope と補足フィールドを記録JSONへ書き、常に exit 0 で返す。
emit_record() {
  local state=$1 reason=$2 scope=$3 note=$4
  local ended_at duration
  ended_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
  duration=$(($(date +%s) - start_epoch))
  jq -n \
    --arg stage "$stage" \
    --arg state "$state" \
    --arg reason "$reason" \
    --arg scope "$scope" \
    --arg note "$note" \
    --arg profile "${profile_name:-}" \
    --arg leadRuntime "$lead_runtime" \
    --arg leadFamily "$lead_family" \
    --arg reqRuntime "${req_runtime:-}" \
    --arg reqModel "${req_model:-}" \
    --arg reqEffort "${req_effort:-}" \
    --arg reqDiversity "${req_diversity:-}" \
    --arg resolvedModel "${resolved_model:-}" \
    --arg resolvedFamily "${resolved_family:-}" \
    --arg established "${established_diversity:-}" \
    --arg cliVersion "${cli_version:-}" \
    --arg tokens "${tokens_used:-}" \
    --arg startedAt "$started_at" \
    --arg endedAt "$ended_at" \
    --argjson durationSeconds "$duration" \
    --arg outputFile "$output_file" \
    --arg artifactDir "$artifact_dir" \
    '{stage: $stage,
      executionState: $state,
      reason: (if $reason == "" then null else $reason end),
      reviewScope: $scope,
      note: (if $note == "" then null else $note end),
      profile: (if $profile == "" then null else $profile end),
      lead: {runtime: $leadRuntime, family: $leadFamily},
      requested: {runtime: (if $reqRuntime == "" then null else $reqRuntime end),
                  model: (if $reqModel == "" then null else $reqModel end),
                  effort: (if $reqEffort == "" then null else $reqEffort end),
                  diversity: (if $reqDiversity == "" then null else $reqDiversity end)},
      resolved: {model: (if $resolvedModel == "" then "unconfirmed" else $resolvedModel end),
                 family: (if $resolvedFamily == "" then "unknown" else $resolvedFamily end)},
      establishedDiversity: (if $established == "" then null else $established end),
      cliVersion: (if $cliVersion == "" then null else $cliVersion end),
      tokens: (if $tokens == "" then null else $tokens end),
      startedAt: $startedAt, endedAt: $endedAt, durationSeconds: $durationSeconds,
      outputFile: $outputFile, artifactDir: $artifactDir}' \
    > "${record_file:-/dev/stdout}"
  exit 0
}

# --- 設定の解決 ---------------------------------------------------------
[[ -f $config_file ]] || emit_record NOT_CONFIGURED config_missing DEGRADED \
  "local/agent-review.json が無いため異種レビューを実行しない(設定なしは正常)"

bash "$root/scripts/agent-review-validate.sh" "$config_file" 2>"$artifact_dir/validate-error.log" ||
  emit_record UNAVAILABLE invalid_configuration DEGRADED \
    "設定がschema不正のため解釈しない: $(head -1 "$artifact_dir/validate-error.log" 2>/dev/null)"

[[ -n $profile_name ]] || profile_name=$(jq -r '.defaultProfile' "$config_file")
profile_json=$(jq --arg p "$profile_name" '.profiles[$p] // empty' "$config_file")
[[ -n $profile_json ]] || emit_record UNAVAILABLE profile_not_found DEGRADED \
  "profile が存在しない: $profile_name"

req_runtime=$(jq -r '.runtime' <<<"$profile_json")
req_model=$(jq -r '.model // ""' <<<"$profile_json")
req_effort=$(jq -r '.effort // ""' <<<"$profile_json")
req_diversity=$(jq -r '.diversity // ""' <<<"$profile_json")
timeout_s=$(jq -r --arg stage "$stage" \
  '.timeoutSeconds // empty' <<<"$profile_json")
[[ -n $timeout_s ]] || timeout_s=$(jq -r --arg stage "$stage" '.defaults.timeoutSeconds[$stage]' "$schema_file")

# 多様性の起動前検査: runtime差を要求するレベル(runtime-only / runtime-and-model-family)は
# 主導と同一runtimeでは成立しない。model-familyのみ同一runtimeを許す(系統差を実測検査)。
if [[ $req_runtime == "$lead_runtime" && $req_diversity != "model-family" ]]; then
  emit_record DIVERSITY_UNSATISFIED resolved_diversity_mismatch DEGRADED \
    "要求 diversity=$req_diversity に対し reviewer runtime が主導と同一: $req_runtime"
fi

case $req_runtime in
  codex-cli) bin=codex ;;
  claude-code-cli) bin=claude ;;
  github-copilot-cli) bin=copilot ;;
  *) emit_record UNAVAILABLE invalid_configuration DEGRADED "未知のruntime: $req_runtime" ;;
esac

command -v "$bin" >/dev/null 2>&1 || emit_record UNAVAILABLE command_not_found DEGRADED \
  "CLIが見つからない: $bin"
cli_version=$("$bin" --version 2>/dev/null | head -1 || true)

# --- timeout watchdog ----------------------------------------------------
# subshellのstderrはjob制御通知("Terminated")の抑止のために捨てる。
# reviewer本体のstderrは $stderr_file へ落ちているため情報は失われない。
run_with_timeout() {
  (
    "$@" >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if ((waited >= timeout_s)); then
        kill -TERM "$pid" 2>/dev/null
        sleep 2
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        exit 124
      fi
      sleep 1
      waited=$((waited + 1))
    done
    wait "$pid"
  ) 2>/dev/null
}

# --- codex impl: 使い捨てworktree + 事後検査(G-0012、#139計画v5/v6) ----
run_codex_impl_in_worktree() {
  local wt="$root/local/worktrees/design-review-$(date +%Y%m%d-%H%M%S)-$$"
  local patch="$artifact_dir/target.patch"
  local head_oid
  head_oid=$(git -C "$root" rev-parse HEAD)

  # untracked一覧はworktree作成前に確定する(作成後だとworktree自身のパスが混入しうる)。
  local untracked_list="$artifact_dir/untracked.list"
  git -C "$root" ls-files --others --exclude-standard >"$untracked_list"

  # 1. 対象HEADからdetached worktreeを作る(launcher異常終了時もtrapで撤収する)
  git -C "$root" worktree add --detach "$wt" "$head_oid" >/dev/null 2>&1 || return 1
  # trapは定義時に展開する(EXIT時にはlocal変数が消えているため)。通常経路では
  # 手順7で撤収済みとなり、このtrapは何もしない。
  # shellcheck disable=SC2064
  trap "git -C '$root' worktree remove --force '$wt' 2>/dev/null || rm -rf '$wt'" EXIT
  # 2. staged + unstaged の最終状態をbinary patchとして固定し適用する
  git -C "$root" diff --binary HEAD >"$patch"
  if [[ -s $patch ]]; then
    git -C "$wt" apply --binary "$patch" || { git -C "$root" worktree remove --force "$wt"; return 1; }
  fi
  # 3. untracked新規ファイルも複製する
  local f
  while IFS= read -r f; do
    mkdir -p "$wt/$(dirname "$f")"
    cp "$root/$f" "$wt/$f"
  done <"$untracked_list"
  # 4. 適用後の状態をsnapshotとして記録する
  snapshot() {
    printf '%s\n' "$(git -C "$wt" rev-parse HEAD)"
    git -C "$wt" diff --binary HEAD | shasum -a 256 | cut -d' ' -f1
    git -C "$wt" ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r u; do
      printf '%s %s\n' "$u" "$(shasum -a 256 "$wt/$u" | cut -d' ' -f1)"
    done
  }
  snapshot >"$artifact_dir/worktree-before.snapshot"

  # reviewerを隔離worktreeで起動する(workspace-write。authoritative側は渡さない)。
  local args=(exec --cd "$wt" -s workspace-write --ephemeral --ignore-user-config --json -o "$output_file")
  [[ -n $out_schema ]] && args+=(--output-schema "$out_schema")
  [[ -n $req_model ]] && args+=(-m "$req_model")
  [[ -n $req_effort ]] && args+=(-c "model_reasoning_effort=\"$req_effort\"")
  local run_rc=0
  run_with_timeout "$bin" "${args[@]}" "$prompt_text" || run_rc=$?

  # 5-6. 起動前後を比較し、改変があれば判定を採用しない
  snapshot >"$artifact_dir/worktree-after.snapshot"
  local mutated=0
  cmp -s "$artifact_dir/worktree-before.snapshot" "$artifact_dir/worktree-after.snapshot" || mutated=1
  # 7. 結果保存後にworktreeを撤収する
  git -C "$root" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  if ((mutated)); then
    emit_record UNAVAILABLE runtime_error DEGRADED \
      "reviewerが隔離worktreeを改変したため判定を採用しない(snapshot不一致)"
  fi
  return "$run_rc"
}

prompt_text=$(cat "$prompt_file")
rc=0
case "$req_runtime:$stage" in
  codex-cli:design)
    # read-only sandbox + user設定由来のMCP等を除外。projectのrules・hooksは維持し、
    # webは有効化しない。禁止toolの不使用はJSONL(stdout log)で事後確認する。
    args=(exec -s read-only --ephemeral --ignore-user-config --json -o "$output_file")
    [[ -n $out_schema ]] && args+=(--output-schema "$out_schema")
    [[ -n $req_model ]] && args+=(-m "$req_model")
    [[ -n $req_effort ]] && args+=(-c "model_reasoning_effort=\"$req_effort\"")
    run_with_timeout "$bin" "${args[@]}" "$prompt_text" || rc=$?
    ;;
  codex-cli:impl)
    # tool allowlistを持たないため、使い捨てdetached worktree + 事後検査で保証する(G-0012)。
    run_codex_impl_in_worktree || rc=$?
    ;;
  claude-code-cli:design)
    # 可視(--tools)と許可(--allowedTools)の2層で読取専用を保証する。
    args=(-p --tools "Read,Grep,Glob" --allowedTools "Read" "Grep" "Glob"
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format json)
    [[ -n $out_schema ]] && args+=(--json-schema "$(cat "$out_schema")")
    [[ -n $req_model ]] && args+=(--model "$req_model")
    [[ -n $req_effort ]] && args+=(--effort "$req_effort")
    run_with_timeout "$bin" "${args[@]}" "$prompt_text" || rc=$?
    ;;
  claude-code-cli:impl)
    args=(-p --tools "Read,Grep,Glob,Bash" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format json
      --allowedTools "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" "Bash(just check)")
    [[ -n $out_schema ]] && args+=(--json-schema "$(cat "$out_schema")")
    [[ -n $req_model ]] && args+=(--model "$req_model")
    [[ -n $req_effort ]] && args+=(--effort "$req_effort")
    run_with_timeout "$bin" "${args[@]}" "$prompt_text" || rc=$?
    ;;
  github-copilot-cli:design)
    # copilotはネイティブのoutput schema機構を持たないため、schema本文をプロンプトへ
    # 機械的に付加して契約を渡す(呼び出し側promptに依存しない)。
    copilot_prompt="$prompt_text

## 出力JSON Schema(この形に厳密に従い、コードフェンスなしのJSONだけを出力する)

$(cat "$out_schema")"
    args=(-p "$copilot_prompt" -s --disable-builtin-mcps --available-tools "view,grep,glob" --allow-tool "view,grep,glob")
    [[ -n $req_model ]] && args+=(--model "$req_model")
    [[ -n $req_effort ]] && args+=(--effort "$req_effort")
    run_with_timeout "$bin" "${args[@]}" || rc=$?
    ;;
  github-copilot-cli:impl)
    copilot_prompt="$prompt_text

## 出力JSON Schema(この形に厳密に従い、コードフェンスなしのJSONだけを出力する)

$(cat "$out_schema")"
    args=(-p "$copilot_prompt" -s --disable-builtin-mcps --available-tools "view,grep,glob,shell"
      --allow-tool "view,grep,glob" --allow-tool "shell(git diff)" --allow-tool "shell(git log)"
      --allow-tool "shell(git show)" --allow-tool "shell(just check)")
    [[ -n $req_model ]] && args+=(--model "$req_model")
    [[ -n $req_effort ]] && args+=(--effort "$req_effort")
    run_with_timeout "$bin" "${args[@]}" || rc=$?
    ;;
esac

# --- 実行結果の分類 ------------------------------------------------------
if ((rc == 124)); then
  emit_record UNAVAILABLE timeout DEGRADED "timeout ${timeout_s}s で強制終了"
fi
combined_log=$(cat "$stdout_file" "$stderr_file" 2>/dev/null || true)
if ((rc != 0)); then
  if grep -qiE "not logged in|/login|authentication|unauthorized" <<<"$combined_log"; then
    emit_record UNAVAILABLE authentication DEGRADED "認証エラー(exit $rc)"
  elif grep -qiE "quota|rate limit|usage limit" <<<"$combined_log"; then
    emit_record UNAVAILABLE quota_exceeded DEGRADED "使用量上限(exit $rc)"
  else
    emit_record UNAVAILABLE runtime_error DEGRADED "起動失敗または非対話中の許可要求(exit $rc)"
  fi
fi

# codex design: JSONL tool logで禁止tool(書込・web・MCP)の不使用を機械確認する。
# read-only sandboxが一次防衛で、これは事後検査(検出したらreview不成立)。
if [[ "$req_runtime:$stage" == "codex-cli:design" ]]; then
  if grep -qE '"type":"(file_change|patch_apply|web_search|web_fetch|mcp_tool_call)"' "$stdout_file" 2>/dev/null; then
    emit_record UNAVAILABLE runtime_error DEGRADED "禁止toolの使用をtool logで検出したためreview不成立"
  fi
fi

# トークン数(取得できるruntimeのみ)。
tokens_used=""
case $req_runtime in
  codex-cli)
    # --json のJSONLでは turn.completed の usage が正(実測: codex-cli 0.149)。
    tokens_used=$(jq -rs '[.[] | select(.type? == "turn.completed")] | last
      | (.usage | (.input_tokens + .output_tokens)) // empty' "$stdout_file" 2>/dev/null || true)
    ;;
  claude-code-cli)
    tokens_used=$(jq -r '.usage.output_tokens // empty' "$stdout_file" 2>/dev/null | head -1 || true)
    ;;
esac

# 出力の取り出し。claude/copilot はstdoutから、フェンスは防御的に除去する。
if [[ $req_runtime != "codex-cli" ]]; then
  if [[ $req_runtime == "claude-code-cli" ]]; then
    # --json-schema の検証済み結果は .structured_output(オブジェクト)へ入る(公式仕様)。
    # .result は文字列fallback(schema未使用時など)。
    if jq -e '.structured_output != null' "$stdout_file" >/dev/null 2>&1; then
      jq -c '.structured_output' "$stdout_file" > "$output_file"
    else
      jq -r '.result // empty' "$stdout_file" 2>/dev/null > "$output_file" || true
    fi
  else
    cp "$stdout_file" "$output_file"
  fi
  # コードフェンス除去(--json-schema等が効いていれば素通り)。
  if ! jq empty "$output_file" 2>/dev/null; then
    sed -n '/^```/,/^```/p' "$output_file" 2>/dev/null | sed '/^```/d' > "$output_file.tmp" || true
    if jq empty "$output_file.tmp" 2>/dev/null; then mv "$output_file.tmp" "$output_file"; else rm -f "$output_file.tmp"; fi
  fi
fi
if [[ ! -s $output_file ]] || ! jq empty "$output_file" 2>/dev/null; then
  emit_record UNAVAILABLE runtime_error DEGRADED "reviewer出力が空、またはJSONとして解釈できない"
fi
# 形だけのJSONをCOMPLETEDにしない。verdictがstage対応の語彙に含まれ、
# 基準正典の必須構造を持つことを検証する。指摘を伴うverdict(REVISE / FAIL)では
# findingsが非空で、各findingが必須フィールドを持つことまで要求する。
verdict_key=$([[ $stage == "design" ]] && echo verdicts || echo implVerdicts)
finding_fields='["target","statement","evidence"]'
vp_pattern=""
if [[ $stage == "design" ]]; then
  finding_fields='["viewpoint","target","statement","evidence"]'
  vp_pattern='^観点[1-5]'
fi
jq -e --slurpfile schema "$schema_file" --arg key "$verdict_key" --argjson ff "$finding_fields" \
  --arg vp "$vp_pattern" \
  '.verdict as $v | ($schema[0].vocabulary[$key] | index($v)) != null
   and (.findings | type == "array") and (.summary | type == "string" and length > 0)
   and ([.findings[] as $f | ($f | type == "object")
         and ([$ff[] as $k | ($f[$k]? | type == "string" and length > 0)] | all)
         and (if $vp == "" then true else ($f.viewpoint? | test($vp)) end)
         and ($schema[0].vocabulary.severities | index($f.severity?) != null)
        ] | all)
   and (if ($v == "REVISE" or $v == "FAIL") then (.findings | length > 0) else true end)' \
  "$output_file" >/dev/null 2>&1 ||
  emit_record UNAVAILABLE runtime_error DEGRADED \
    "reviewer出力が基準正典の構造(verdict語彙・findingsの型と非空・severity・summary)を満たさない"

# --- 解決モデルと diversity 判定 ----------------------------------------
resolved_model=""
case $req_runtime in
  codex-cli)
    resolved_model=$(grep -o '"model":"[^"]*"' "$stdout_file" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
    ;;
  claude-code-cli)
    resolved_model=$(jq -r '(.modelUsage // {}) | to_entries | sort_by(-(.value.outputTokens // 0)) | .[0].key // empty' \
      "$stdout_file" 2>/dev/null || true)
    ;;
  github-copilot-cli)
    # -s のstdoutは応答本文のみで、解決モデルの機械的な取得源が無い(本文grepは
    # レビュー内容を誤認するため行わない)。常にunconfirmedとし、model系レベルの
    # 要求はDIVERSITY_UNSATISFIEDになる。
    resolved_model=""
    ;;
esac

resolved_family=""
if [[ -n $resolved_model ]]; then
  resolved_family=$(jq -r --arg m "$resolved_model" \
    '[.familyPatterns[] | .pattern as $p | .family as $f | select($m | test($p)) | $f] | first // "unknown"' \
    "$schema_file")
fi

# 成立した多様性レベルを解決値から確定し、要求レベルと突き合わせる(要求値で代用しない)。
runtime_differs=0
family_differs=0
if [[ $req_runtime != "$lead_runtime" ]]; then runtime_differs=1; fi
if [[ -n $resolved_model && $resolved_family != "unknown" && $resolved_family != "$lead_family" ]]; then
  family_differs=1
fi
established_diversity="none"
if ((runtime_differs && family_differs)); then
  established_diversity="runtime-and-model-family"
elif ((family_differs)); then
  established_diversity="model-family"
elif ((runtime_differs)); then
  established_diversity="runtime-only"
fi

satisfied=0
case $req_diversity in
  runtime-only) if ((runtime_differs)); then satisfied=1; fi ;;
  model-family) if ((family_differs)); then satisfied=1; fi ;;
  runtime-and-model-family) if ((runtime_differs && family_differs)); then satisfied=1; fi ;;
esac
if ((satisfied == 0)); then
  emit_record DIVERSITY_UNSATISFIED resolved_diversity_mismatch DEGRADED \
    "要求 diversity=${req_diversity} を満たさない(成立=${established_diversity}、解決モデル=${resolved_model:-unconfirmed})"
fi
emit_record COMPLETED "" FULL ""
