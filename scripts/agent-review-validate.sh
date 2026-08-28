#!/usr/bin/env bash
# local/agent-review.json の共通validator(G-0012)。
# check-agent-config.sh と design-review.sh の両方がこれを呼ぶ。検証ロジックを複製しない。
# 検証の意味論: schema構造・enum・型のみを見る。profile名の解決(不存在)はlauncherの
# 責務(UNAVAILABLE(profile_not_found))であり、ここでは失敗にしない。
# exit 0 = 有効 / exit 2 = 不正(理由をstderrへ)。
set -euo pipefail

config_file=${1:?usage: agent-review-validate.sh <config-file>}
schema_file="$(git rev-parse --show-toplevel)/.agents/agent-review.schema.json"

fail() {
  echo "agent-review-validate: $1" >&2
  exit 2
}

[[ -f $config_file ]] || fail "設定ファイルが存在しない: $config_file"
jq empty "$config_file" 2>/dev/null || fail "JSONとして解析できない: $config_file"

jq -e --slurpfile schema "$schema_file" '
  . as $cfg
  | ($schema[0].vocabulary.runtimes) as $runtimes
  | ($schema[0].vocabulary.diversity) as $diversity
  | ($schema[0].config.required) as $required
  | ($schema[0].config.profileRequired) as $profileRequired
  | ($schema[0].config.profileOptional) as $profileOptional
  # 必須トップレベルフィールド
  | ([$required[] as $k | ($cfg | has($k))] | all)
  # 未知キーを黙って解釈しない(fail-closed)。トップレベルはrequired+comment、
  # profileはprofileRequired+profileOptionalのみを許す。
  and (($cfg | keys) - ($required + ["comment"]) | length == 0)
  # 型と値
  and ($cfg.schemaVersion == $schema[0].schemaVersion)
  and ($cfg.defaultProfile | type == "string" and length > 0)
  and ($cfg.profiles | type == "object" and length > 0)
  # 各profileの構造
  and ([$cfg.profiles[] as $p |
        ([$profileRequired[] as $k | ($p | has($k))] | all)
        and (($p | keys) - ($profileRequired + $profileOptional) | length == 0)
        and ($runtimes | index($p.runtime) != null)
        and (if $p | has("diversity") then ($diversity | index($p.diversity) != null) else true end)
        and (if $p | has("timeoutSeconds") then ($p.timeoutSeconds | type == "number" and . == floor and . >= 1) else true end)
        and (if $p | has("model") then ($p.model | type == "string" and length > 0) else true end)
        and (if $p | has("effort") then ($p.effort | type == "string" and length > 0) else true end)
       ] | all)
' "$config_file" >/dev/null ||
  fail "schema不正(agent-review.schema.json の config/vocabulary を満たさない): $config_file"

exit 0
