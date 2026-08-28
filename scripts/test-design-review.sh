#!/usr/bin/env bash
# design-review.sh(異種reviewer起動アダプター)の決定的テスト。
# 実CLI・認証・課金へ触れないよう、PATHを固定しstub runtimeで全経路を検証する(G-0012)。
set -euo pipefail

source_root=$(git rev-parse --show-toplevel)
fixture_parent=$(mktemp -d)

case "$fixture_parent" in
  /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*) ;;
  *)
    echo "unsafe temporary directory: $fixture_parent" >&2
    exit 1
    ;;
esac

cleanup() {
  if [[ -n ${fixture_parent:-} && -d $fixture_parent ]]; then
    rm -rf -- "$fixture_parent"
  fi
}
trap cleanup EXIT

fixture_root="$fixture_parent/repository"
stub_bin="$fixture_parent/bin"
mkdir -p "$fixture_root/.agents" "$fixture_root/scripts" "$fixture_root/local" "$stub_bin"

cp "$source_root/.agents/agent-review.schema.json" "$fixture_root/.agents/"
cp "$source_root/scripts/design-review.sh" "$source_root/scripts/agent-review-validate.sh" "$fixture_root/scripts/"

# 実CLI(codex / claude / copilot)へ到達しないPATHを作る。jq・shasumだけ実物を通す。
ln -s "$(command -v jq)" "$stub_bin/jq"
export PATH="$stub_bin:/usr/bin:/bin"

cd "$fixture_root"
git init --quiet
printf 'base\n' > tracked.txt
git add tracked.txt
git -c user.email=test@example.com -c user.name=test commit -qm init
printf 'レビュー指示(テスト用)\n' > prompt.md
printf '{"type":"object"}\n' > out-schema.json

# stub codex: STUB_MODE で挙動を切り替える。
cat > "$stub_bin/codex" <<'STUB'
#!/bin/bash
out="" wt=""
if [[ ${1:-} == "--version" ]]; then echo "codex-cli stub 0.0.1"; exit 0; fi
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -o) out=${args[i + 1]} ;;
    --cd) wt=${args[i + 1]} ;;
  esac
done
case ${STUB_MODE:-normal} in
  normal)
    echo '{"type":"turn.started","model":"gpt-test"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":234}}'
    printf '{"verdict":"READY","findings":[],"summary":"stub"}' > "$out"
    ;;
  same-family)
    echo '{"type":"turn.started","model":"claude-stub"}'
    printf '{"verdict":"READY","findings":[],"summary":"stub"}' > "$out"
    ;;
  no-model)
    echo '{"type":"turn.started"}'
    printf '{"verdict":"READY","findings":[],"summary":"stub"}' > "$out"
    ;;
  garbage)
    printf 'not json' > "$out"
    ;;
  empty-out)
    : > "$out"
    ;;
  wrong-shape)
    printf '{}' > "$out"
    ;;
  verdict-only)
    printf '{"verdict":"READY"}' > "$out"
    ;;
  revise-empty)
    printf '{"verdict":"REVISE","findings":[],"summary":"stub"}' > "$out"
    ;;
  nonobject-finding)
    printf '{"verdict":"REVISE","findings":["not an object"],"summary":"stub"}' > "$out"
    ;;
  bad-viewpoint)
    printf '{"verdict":"REVISE","findings":[{"viewpoint":"perspective-9","target":"t","statement":"x","evidence":"y","severity":"blocking"}],"summary":"stub"}' > "$out"
    ;;
  bad-finding)
    printf '{"verdict":"REVISE","findings":[{"viewpoint":"観点1","target":"","statement":"x","evidence":"y","severity":"critical"}],"summary":"stub"}' > "$out"
    ;;
  permission-prompt)
    echo "This command requires approval. Waiting for confirmation..."
    exit 1
    ;;
  quota-fail)
    echo "monthly usage limit reached"
    exit 1
    ;;
  forbidden-tool)
    echo '{"type":"turn.started","model":"gpt-test"}'
    echo '{"type":"web_search","query":"evil"}'
    printf '{"verdict":"READY","findings":[],"summary":"stub"}' > "$out"
    ;;
  hang)
    sleep 60
    ;;
  auth-fail)
    echo "Not logged in · Please run /login"
    exit 1
    ;;
  impl-observe)
    saw_staged=false; saw_unstaged=false; saw_untracked=false
    grep -q staged-content "$wt/tracked.txt" && saw_staged=true
    grep -q unstaged-content "$wt/second.txt" 2>/dev/null && saw_unstaged=true
    [[ -f $wt/new-untracked.txt ]] && saw_untracked=true
    printf '{"verdict":"PASS","findings":[],"summary":"stub","sawStaged":%s,"sawUnstaged":%s,"sawUntracked":%s}' \
      "$saw_staged" "$saw_unstaged" "$saw_untracked" > "$out"
    ;;
  impl-mutate-tracked)
    echo evil >> "$wt/tracked.txt"
    printf '{"verdict":"PASS"}' > "$out"
    ;;
  impl-mutate-untracked)
    echo evil > "$wt/evil.txt"
    printf '{"verdict":"PASS"}' > "$out"
    ;;
  impl-commit)
    git -C "$wt" add -A
    git -C "$wt" -c user.email=s@example.com -c user.name=s commit -qm evil
    printf '{"verdict":"PASS"}' > "$out"
    ;;
esac
exit 0
STUB
chmod +x "$stub_bin/codex"

case_no=0
run_launcher() {
  local stage=$1
  case_no=$((case_no + 1))
  bash scripts/design-review.sh --stage "$stage" \
    --lead-runtime "${LEAD_RUNTIME:-claude-code-cli}" --lead-family "${LEAD_FAMILY:-anthropic}" \
    --prompt-file prompt.md --output-schema out-schema.json --record-file record.json \
    --artifact-dir "$fixture_parent/artifacts/case-$case_no"
}

expect() {
  local name=$1 state=$2 reason=$3
  jq -e --arg s "$state" --arg r "$reason" \
    '.executionState == $s and ((.reason // "") == $r)' record.json >/dev/null ||
    {
      echo "design-review test failed: $name: $(cat record.json)" >&2
      exit 1
    }
}

write_config() {
  cat > local/agent-review.json
}

# 1. 設定なし → NOT_CONFIGURED(config_missing)
rm -f local/agent-review.json
run_launcher design
expect "設定なし" NOT_CONFIGURED config_missing

# 2. schema不正 → UNAVAILABLE(invalid_configuration)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p", "profiles": {"p": {"runtime": "bogus-cli"}}}
EOF
run_launcher design
expect "schema不正" UNAVAILABLE invalid_configuration

# 2b. diversity欠落(profile必須フィールド) → UNAVAILABLE(invalid_configuration)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p", "profiles": {"p": {"runtime": "codex-cli"}}}
EOF
run_launcher design
expect "diversity欠落" UNAVAILABLE invalid_configuration

# 2c. 未知のprofileキー(誤記 effrot) → UNAVAILABLE(invalid_configuration)(黙って解釈しない)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only", "effrot": "high"}}}
EOF
run_launcher design
expect "未知profileキー" UNAVAILABLE invalid_configuration

# 3. profile不存在(defaultProfile参照切れ) → UNAVAILABLE(profile_not_found)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "missing", "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only"}}}
EOF
run_launcher design
expect "profile不存在" UNAVAILABLE profile_not_found

# 4. CLI不在 → UNAVAILABLE(command_not_found)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p", "profiles": {"p": {"runtime": "github-copilot-cli", "diversity": "runtime-only"}}}
EOF
run_launcher design
expect "CLI不在" UNAVAILABLE command_not_found

# 5. 正常完了 → COMPLETED、解決モデル・family・CLI version・トークンを記録
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-and-model-family"}}}
EOF
STUB_MODE=normal run_launcher design
expect "正常完了" COMPLETED ""
jq -e '.resolved.model == "gpt-test" and .resolved.family == "openai"
  and .cliVersion == "codex-cli stub 0.0.1" and .tokens == "1234"
  and .reviewScope == "FULL" and .establishedDiversity == "runtime-and-model-family"' record.json >/dev/null ||
  {
    echo "design-review test failed: 正常完了の記録内容: $(cat record.json)" >&2
    exit 1
  }

# 6. 解決モデルが主導と同系 → DIVERSITY_UNSATISFIED(resolved_diversity_mismatch)
STUB_MODE=same-family run_launcher design
expect "解決モデル同系" DIVERSITY_UNSATISFIED resolved_diversity_mismatch

# 7. 解決モデル不明(unconfirmed) → 要求値で代用せず DIVERSITY_UNSATISFIED
STUB_MODE=no-model run_launcher design
expect "解決モデルunconfirmed" DIVERSITY_UNSATISFIED resolved_diversity_mismatch
jq -e '.resolved.model == "unconfirmed"' record.json >/dev/null ||
  {
    echo "design-review test failed: unconfirmedの記録: $(cat record.json)" >&2
    exit 1
  }

# 8. runtime同一 + runtime-and-model-family → 起動前に DIVERSITY_UNSATISFIED
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "claude-code-cli", "diversity": "runtime-and-model-family"}}}
EOF
run_launcher design
expect "runtime同一" DIVERSITY_UNSATISFIED resolved_diversity_mismatch

# 8b. 同一runtime + runtime-only → 起動前に DIVERSITY_UNSATISFIED
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "claude-code-cli", "diversity": "runtime-only"}}}
EOF
run_launcher design
expect "同一runtime・runtime-only" DIVERSITY_UNSATISFIED resolved_diversity_mismatch

# 8d. runtime-only + 解決モデル未確認 → runtime差のみでCOMPLETED/FULL(codexの実用経路)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only"}}}
EOF
STUB_MODE=no-model run_launcher design
expect "runtime-only成立" COMPLETED ""
jq -e '.establishedDiversity == "runtime-only" and .resolved.model == "unconfirmed"
  and .reviewScope == "FULL"' record.json >/dev/null ||
  {
    echo "design-review test failed: runtime-only成立の記録: $(cat record.json)" >&2
    exit 1
  }

# 8c. 小数のtimeoutSeconds → schema不正(watchdogの整数演算と不整合のため受理しない)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only", "timeoutSeconds": 0.5}}}
EOF
run_launcher design
expect "小数timeout" UNAVAILABLE invalid_configuration

# 9. timeout → UNAVAILABLE(timeout)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only", "timeoutSeconds": 1}}}
EOF
STUB_MODE=hang run_launcher design
expect "timeout" UNAVAILABLE timeout

# 10. 出力がJSONでない → UNAVAILABLE(runtime_error)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only"}}}
EOF
STUB_MODE=garbage run_launcher design
expect "出力schema不一致" UNAVAILABLE runtime_error

# 10b. 出力が空 → COMPLETEDへ誤分類せず UNAVAILABLE(runtime_error)
STUB_MODE=empty-out run_launcher design
expect "出力が空" UNAVAILABLE runtime_error

# 10c. JSONだがverdictが語彙に無い(形だけのJSON) → UNAVAILABLE(runtime_error)
STUB_MODE=wrong-shape run_launcher design
expect "verdictが語彙に無い" UNAVAILABLE runtime_error

# 10d. verdictは語彙内だがfindings/summaryが欠落 → UNAVAILABLE(runtime_error)
STUB_MODE=verdict-only run_launcher design
expect "必須構造の欠落" UNAVAILABLE runtime_error

# 10e. tool logに禁止toolイベント → UNAVAILABLE(runtime_error)
STUB_MODE=forbidden-tool run_launcher design
expect "禁止tool検出" UNAVAILABLE runtime_error

# 10f. REVISEなのにfindingsが空(引用義務違反) → UNAVAILABLE(runtime_error)
STUB_MODE=revise-empty run_launcher design
expect "REVISEでfindings空" UNAVAILABLE runtime_error

# 10h. findingの型・enum不正(空target・severity語彙外) → UNAVAILABLE(runtime_error)
STUB_MODE=bad-finding run_launcher design
expect "finding構造不正" UNAVAILABLE runtime_error

# 10i. findings要素が非オブジェクト → UNAVAILABLE(runtime_error)
STUB_MODE=nonobject-finding run_launcher design
expect "finding非オブジェクト" UNAVAILABLE runtime_error

# 10j. viewpointが観点1〜5でない → UNAVAILABLE(runtime_error)
STUB_MODE=bad-viewpoint run_launcher design
expect "viewpoint不正" UNAVAILABLE runtime_error

# 10g. 非対話中の許可要求(プロンプト待ちで非zero終了) → UNAVAILABLE(runtime_error)
STUB_MODE=permission-prompt run_launcher design
expect "非対話許可要求" UNAVAILABLE runtime_error

# 11. 認証エラー → UNAVAILABLE(authentication)
STUB_MODE=auth-fail run_launcher design
expect "認証エラー" UNAVAILABLE authentication

# 11b. 使用量上限 → UNAVAILABLE(quota_exceeded)
STUB_MODE=quota-fail run_launcher design
expect "使用量上限" UNAVAILABLE quota_exceeded

# 11c. claude分岐: --json-schema と --allowedTools が渡り、result/modelUsage を抽出する
cat > "$stub_bin/claude" <<'CSTUB'
#!/bin/bash
if [[ ${1:-} == "--version" ]]; then echo "claude stub 0.0.1"; exit 0; fi
printf '%s\n' "$*" > "${CLAUDE_STUB_ARGS:-/dev/null}"
sed "s/__MODEL__/${CLAUDE_STUB_MODEL:-claude-stub-model}/" <<'JSONEOF'
{"type":"result","result":"unused-fallback","structured_output":{"verdict":"READY","findings":[],"summary":"stub"},"usage":{"output_tokens":42},"modelUsage":{"__MODEL__":{"outputTokens":42}}}
JSONEOF
CSTUB
chmod +x "$stub_bin/claude"
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "claude-code-cli", "diversity": "runtime-and-model-family"}}}
EOF
CLAUDE_STUB_ARGS="$fixture_parent/claude-args.txt" LEAD_RUNTIME=codex-cli LEAD_FAMILY=openai \
  run_launcher design
expect "claude分岐" COMPLETED ""
jq -e '.resolved.model == "claude-stub-model" and .resolved.family == "anthropic" and .tokens == "42"
  and .establishedDiversity == "runtime-and-model-family"' record.json >/dev/null ||
  {
    echo "design-review test failed: claude分岐の抽出: $(cat record.json)" >&2
    exit 1
  }
grep -qF -- '--json-schema {' "$fixture_parent/claude-args.txt" &&
  grep -q -- "--allowedTools" "$fixture_parent/claude-args.txt" &&
  grep -q -- "--strict-mcp-config" "$fixture_parent/claude-args.txt" ||
  {
    echo "design-review test failed: claude起動引数に2層制限またはschema本文が無い: $(cat "$fixture_parent/claude-args.txt")" >&2
    exit 1
  }
# 11f. model-family + 同一runtime + 異系統解決モデル → COMPLETED(established=model-family)
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "claude-code-cli", "diversity": "model-family"}}}
EOF
CLAUDE_STUB_MODEL=gpt-stub-model run_launcher design
expect "model-family成立" COMPLETED ""
jq -e '.establishedDiversity == "model-family" and .resolved.family == "openai"
  and .reviewScope == "FULL"' record.json >/dev/null ||
  {
    echo "design-review test failed: model-family成立の記録: $(cat record.json)" >&2
    exit 1
  }

# 11g. model-family + 同系統解決モデル → DIVERSITY_UNSATISFIED
CLAUDE_STUB_MODEL=claude-stub-model LEAD_RUNTIME=codex-cli LEAD_FAMILY=anthropic run_launcher design
expect "model-family不成立" DIVERSITY_UNSATISFIED resolved_diversity_mismatch
rm -f "$stub_bin/claude"

# 11d. copilot分岐(design): tool 2層制限・model/effort・出力抽出を検証
cat > "$stub_bin/copilot" <<'PSTUB'
#!/bin/bash
if [[ ${1:-} == "--version" ]]; then echo "copilot stub 0.0.1"; exit 0; fi
printf '%s
' "$*" > "${COPILOT_STUB_ARGS:-/dev/null}"
printf '{"verdict":"%s","findings":[],"summary":"stub review mentioning model gpt-fake-5 in body"}
' "${COPILOT_STUB_VERDICT:-READY}"
PSTUB
chmod +x "$stub_bin/copilot"
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "github-copilot-cli", "model": "gpt-test", "effort": "medium", "diversity": "runtime-only"}}}
EOF
COPILOT_STUB_ARGS="$fixture_parent/copilot-args.txt" run_launcher design
expect "copilot design分岐" COMPLETED ""
grep -q -- " -s " "$fixture_parent/copilot-args.txt" &&
  grep -qF -- '"type":"object"' "$fixture_parent/copilot-args.txt" &&
  grep -q -- "出力JSON Schema" "$fixture_parent/copilot-args.txt" &&
  grep -q -- "--available-tools" "$fixture_parent/copilot-args.txt" &&
  grep -q -- "--allow-tool" "$fixture_parent/copilot-args.txt" &&
  grep -q -- "--disable-builtin-mcps" "$fixture_parent/copilot-args.txt" &&
  grep -q -- "--model gpt-test" "$fixture_parent/copilot-args.txt" &&
  grep -q -- "--effort medium" "$fixture_parent/copilot-args.txt" ||
  {
    echo "design-review test failed: copilot design引数(schema本文付加を含む): $(cat "$fixture_parent/copilot-args.txt")" >&2
    exit 1
  }

# 11e. copilot分岐(impl): 許可コマンドの限定(shell(git diff)等)が渡る
COPILOT_STUB_ARGS="$fixture_parent/copilot-args-impl.txt" COPILOT_STUB_VERDICT=PASS run_launcher impl
expect "copilot impl分岐" COMPLETED ""
grep -qF -- "shell(git diff)" "$fixture_parent/copilot-args-impl.txt" &&
  grep -qF -- "shell(just check)" "$fixture_parent/copilot-args-impl.txt" &&
  ! grep -q -- "--allow-all-tools" "$fixture_parent/copilot-args-impl.txt" ||
  {
    echo "design-review test failed: copilot impl引数: $(cat "$fixture_parent/copilot-args-impl.txt")" >&2
    exit 1
  }
# 11h. copilot + model-family → 解決モデルの取得源が無く DIVERSITY_UNSATISFIED
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "github-copilot-cli", "diversity": "model-family"}}}
EOF
run_launcher design
expect "copilot model-family不成立" DIVERSITY_UNSATISFIED resolved_diversity_mismatch
jq -e '.resolved.model == "unconfirmed"' record.json >/dev/null ||
  {
    echo "design-review test failed: copilot解決モデルの記録: $(cat record.json)" >&2
    exit 1
  }
rm -f "$stub_bin/copilot"

# 12以降はcodex runtimeへ戻す(11cでclaudeへ書き換えたため)。
write_config <<'EOF'
{"schemaVersion": 1, "defaultProfile": "p",
 "profiles": {"p": {"runtime": "codex-cli", "diversity": "runtime-only"}}}
EOF

# 12. impl: staged / unstaged / untracked がすべて隔離worktreeから見える。
# staged / unstaged の内容はHEADに存在させない(commitしない)ことで、
# patch(`git diff --binary HEAD`)の適用が無ければstubのgrepが失敗する形にする。
printf 'base2\n' > second.txt
git add second.txt
git -c user.email=test@example.com -c user.name=test commit -qm second
printf 'staged-content\n' > tracked.txt
git add tracked.txt
printf 'unstaged-content\n' >> second.txt
printf 'untracked\n' > new-untracked.txt
git diff --cached --quiet && {
  echo "design-review test failed: fixtureにstaged変更が無い(前提が壊れている)" >&2
  exit 1
}
STUB_MODE=impl-observe run_launcher impl
expect "impl正常" COMPLETED ""
jq -e '.sawStaged == true and .sawUnstaged == true and .sawUntracked == true' \
  "$fixture_parent/artifacts/case-$case_no/reviewer-output.json" >/dev/null ||
  {
    echo "design-review test failed: implでコミット前変更が見えない: $(cat "$fixture_parent/artifacts/case-$case_no/reviewer-output.json")" >&2
    exit 1
  }

# 13. impl: reviewerによるtracked改変 → UNAVAILABLE(runtime_error)
STUB_MODE=impl-mutate-tracked run_launcher impl
expect "impl tracked改変" UNAVAILABLE runtime_error

# 14. impl: reviewerによるuntracked追加 → UNAVAILABLE(runtime_error)
STUB_MODE=impl-mutate-untracked run_launcher impl
expect "impl untracked追加" UNAVAILABLE runtime_error

# 15. impl: reviewerによるcommit(HEAD変更) → UNAVAILABLE(runtime_error)
STUB_MODE=impl-commit run_launcher impl
expect "impl HEAD変更" UNAVAILABLE runtime_error

# 16. worktreeが撤収されている
remaining=$(ls "$fixture_root/local/worktrees" 2>/dev/null | wc -l | tr -d ' ')
[[ $remaining == 0 ]] ||
  {
    echo "design-review test failed: 使い捨てworktreeが残存: $remaining 件" >&2
    exit 1
  }

# 語彙drift検査: launcherが発する実行状態・理由のリテラルがschemaの語彙に含まれる
# (語彙の正典はschema。改名時にscript側の取り残しをここで検出する)。
schema_json="$fixture_root/.agents/agent-review.schema.json"
while read -r state reason; do
  jq -e --arg w "$state" '.vocabulary.executionStates | index($w) != null' "$schema_json" >/dev/null ||
    {
      echo "design-review test failed: schemaに無い実行状態リテラル: $state" >&2
      exit 1
    }
  if [[ $reason != '""' && -n $reason ]]; then
    jq -e --arg w "$reason" '.vocabulary.unavailableReasons | index($w) != null' "$schema_json" >/dev/null ||
      {
        echo "design-review test failed: schemaに無い理由リテラル: $reason" >&2
        exit 1
      }
  fi
done < <(grep -oE 'emit_record [A-Z_]+ [a-z_"]+' scripts/design-review.sh | awk '{print $2, $3}' | sort -u)

echo "design-review tests passed"
