#!/usr/bin/env bash
# coverage-sensor.sh の実効テスト(G-0013)。analyzeの境界・fail-closed条件と、
# measureの失敗伝播・成功経路argvを、合成fixtureとPATHスタブで検証する。
# Swiftビルドを要しない純ロジック検査であり、just check(CIと同一)で実行する。
set -euo pipefail

source_root=$(git rev-parse --show-toplevel)
sensor="$source_root/scripts/coverage-sensor.sh"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/coverage-sensor-test.XXXXXX")

case "$fixture_dir" in
  /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*) ;;
  *)
    echo "unsafe temporary directory: $fixture_dir" >&2
    exit 1
    ;;
esac

cleanup() {
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

fx_root="/fx-root"
scope="Packages/MimizukuCore/Sources/MimizukuCore"
export_base="$fixture_dir/export-base.json"
ladder_empty="$fixture_dir/ladder-empty.json"

# 合成export: スコープ内2関数(s1=全カバー、s2=未カバー1 region)+スコープ外1関数。
jq -n --arg root "$fx_root" --arg scope "$scope" '
{
  version: "3.0.1",
  data: [{
    functions: [
      {name: "s1", filenames: [($root + "/" + $scope + "/A.swift")],
       regions: [[10,1,12,2,5,0,0,0],[13,1,14,2,3,0,0,0]], count: 5},
      {name: "s2", filenames: [($root + "/" + $scope + "/B.swift")],
       regions: [[20,1,25,2,0,0,0,0],[26,1,27,2,1,0,0,0]], count: 1},
      {name: "t1", filenames: [($root + "/Packages/MimizukuCore/Tests/MimizukuCoreTests/X.swift")],
       regions: [[1,1,2,2,0,0,0,0]], count: 0}
    ]
  }]
}' >"$export_base"
printf '%s\n' '{"schemaVersion": 1, "entries": []}' >"$ladder_empty"

run_analyze() {
  local export_json=$1
  local ladder=$2
  COVERAGE_SENSOR_ROOT="$fx_root" COVERAGE_SENSOR_WONTCOVER="$ladder" \
    bash "$sensor" analyze "$export_json" 2>&1
}

pass_count=0

expect_ok() {
  local name=$1 export_json=$2 ladder=$3 must_contain=$4
  local output status
  set +e
  output=$(run_analyze "$export_json" "$ladder")
  status=$?
  set -e
  [[ $status -eq 0 ]] || {
    echo "coverage sensor test failed: $name: exit=$status output=$output" >&2
    exit 1
  }
  grep -Fq "$must_contain" <<<"$output" || {
    echo "coverage sensor test failed: $name: 「$must_contain」が出力にない: $output" >&2
    exit 1
  }
  pass_count=$((pass_count + 1))
}

expect_ok_without() {
  local name=$1 export_json=$2 ladder=$3 must_not_contain=$4
  local output status
  set +e
  output=$(run_analyze "$export_json" "$ladder")
  status=$?
  set -e
  [[ $status -eq 0 ]] || {
    echo "coverage sensor test failed: $name: exit=$status output=$output" >&2
    exit 1
  }
  if grep -Fq "$must_not_contain" <<<"$output"; then
    echo "coverage sensor test failed: $name: 「$must_not_contain」が出力に含まれてはならない: $output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_fail() {
  local name=$1 export_json=$2 ladder=$3 expected=$4
  local output status
  set +e
  output=$(run_analyze "$export_json" "$ladder")
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo "coverage sensor test failed: $name: 失敗すべきところ成功した: $output" >&2
    exit 1
  }
  grep -Fq "$expected" <<<"$output" || {
    echo "coverage sensor test failed: $name: 「$expected」がエラー出力にない: $output" >&2
    exit 1
  }
  pass_count=$((pass_count + 1))
}

mutate_export() {
  local out=$1
  shift
  jq "$@" "$export_base" >"$out"
}

make_ladder() {
  local out=$1 file=$2 symbol=$3 reason=$4 regions=$5 uncovered=$6
  jq -n --arg file "$file" --arg symbol "$symbol" --arg reason "$reason" \
    --argjson regions "$regions" --argjson uncovered "$uncovered" \
    '{schemaVersion: 1, entries: [{file: $file, symbol: $symbol, reason: $reason,
      registeredRegions: $regions, registeredUncovered: $uncovered}]}' >"$out"
}

# --- 正常系・控除・失効 ---
expect_ok "未カバー列挙(rel+demangle表示+件数)" "$export_base" "$ladder_empty" "$scope/B.swift"
expect_ok "未カバー件数と行番号" "$export_base" "$ladder_empty" "1/2	lines:20"
expect_ok_without "カバー済み関数は出力しない" "$export_base" "$ladder_empty" "A.swift"
expect_ok_without "スコープ外関数は出力しない" "$export_base" "$ladder_empty" "X.swift"
expect_ok "summary行" "$export_base" "$ladder_empty" "summary: scoped_functions=2 total_regions=4 uncovered_functions=1 uncovered_regions=1 wontcover_valid=0 wontcover_expired=0"

ladder_valid="$fixture_dir/ladder-valid.json"
make_ladder "$ladder_valid" "$scope/B.swift" "s2" "復旧経路のOSエラー分岐で恒常再現が不可能" 2 1
expect_ok "台帳有効控除でset point reached" "$export_base" "$ladder_valid" "set point reached"
expect_ok_without "有効控除された関数は出力しない" "$export_base" "$ladder_valid" "B.swift"

ladder_file_mismatch="$fixture_dir/ladder-file-mismatch.json"
make_ladder "$ladder_file_mismatch" "$scope/C.swift" "s2" "r" 2 1
expect_ok "失効(file不一致)" "$export_base" "$ladder_file_mismatch" "expired: s2 — file不一致"
expect_ok "失効時は未カバーが出力へ戻る" "$export_base" "$ladder_file_mismatch" "$scope/B.swift"
expect_ok_without "失効時はset point reachedにならない" "$export_base" "$ladder_file_mismatch" "set point reached"

ladder_regions_mismatch="$fixture_dir/ladder-regions-mismatch.json"
make_ladder "$ladder_regions_mismatch" "$scope/B.swift" "s2" "r" 3 1
expect_ok "失効(region総数不一致)" "$export_base" "$ladder_regions_mismatch" "expired: s2 — region総数不一致"

ladder_uncovered_mismatch="$fixture_dir/ladder-uncovered-mismatch.json"
make_ladder "$ladder_uncovered_mismatch" "$scope/B.swift" "s2" "r" 2 0
expect_ok "失効(未カバー数不一致)" "$export_base" "$ladder_uncovered_mismatch" "expired: s2 — 未カバー数不一致"

# --- checkout位置非依存(別ルートでも同じ台帳が有効) ---
export_other_root="$fixture_dir/export-other-root.json"
jq --arg from "$fx_root/" --arg to "/other-root/" \
  '(.data[0].functions[].filenames) |= map(sub("^" + $from; $to))' \
  "$export_base" >"$export_other_root"
output=$(COVERAGE_SENSOR_ROOT="/other-root" COVERAGE_SENSOR_WONTCOVER="$ladder_valid" \
  bash "$sensor" analyze "$export_other_root" 2>&1) || {
  echo "coverage sensor test failed: checkout位置非依存: $output" >&2
  exit 1
}
grep -Fq "set point reached" <<<"$output" || {
  echo "coverage sensor test failed: checkout位置非依存: set point reachedが出ない: $output" >&2
  exit 1
}
pass_count=$((pass_count + 1))

# --- 台帳の照合エラー(stale・曖昧・重複) ---
ladder_stale="$fixture_dir/ladder-stale.json"
make_ladder "$ladder_stale" "$scope/B.swift" "nope" "r" 2 1
expect_fail "staleシンボル" "$export_base" "$ladder_stale" "stale"

export_dup="$fixture_dir/export-dup-symbol.json"
mutate_export "$export_dup" '.data[0].functions += [.data[0].functions[1]]'
expect_fail "export内同名symbol(曖昧)" "$export_dup" "$ladder_valid" "複数に一致(曖昧)"

ladder_dup="$fixture_dir/ladder-dup.json"
jq '.entries += .entries' "$ladder_valid" >"$ladder_dup"
expect_fail "台帳内symbol重複" "$export_base" "$ladder_dup" "symbolが重複"

# --- 台帳schema違反 ---
for case_spec in \
  'reason空|.entries[0].reason = ""|reasonが欠落・空' \
  'reason欠落|del(.entries[0].reason)|reasonが欠落・空' \
  'file空|.entries[0].file = ""|fileが欠落・空' \
  'symbol空|.entries[0].symbol = ""|symbolが欠落・空' \
  'file絶対パス|.entries[0].file = "/abs/B.swift"|ルート相対のスコープ内パスでない' \
  'file相対親参照|.entries[0].file = "Packages/MimizukuCore/Sources/MimizukuCore/../X.swift"|ルート相対のスコープ内パスでない' \
  'fileスコープ外|.entries[0].file = "Packages/MimizukuCore/Tests/T.swift"|ルート相対のスコープ内パスでない' \
  'registeredRegions文字列|.entries[0].registeredRegions = "2"|registeredRegionsが非負整数でない' \
  'registeredRegions負数|.entries[0].registeredRegions = -1|registeredRegionsが非負整数でない' \
  'registeredRegions非整数|.entries[0].registeredRegions = 1.5|registeredRegionsが非負整数でない' \
  'registeredUncovered非整数|.entries[0].registeredUncovered = 0.5|registeredUncoveredが非負整数でない' \
  'entries非配列|.entries = {}|entriesが配列でない' \
  'schemaVersion不正|.schemaVersion = 2|schemaVersionが1でない'; do
  IFS='|' read -r case_name mutation expected <<<"$case_spec"
  ladder_broken="$fixture_dir/ladder-broken.json"
  jq "$mutation" "$ladder_valid" >"$ladder_broken"
  expect_fail "台帳$case_name" "$export_base" "$ladder_broken" "$expected"
done

ladder_missing="$fixture_dir/no-such-ladder.json"
expect_fail "台帳ファイル欠損" "$export_base" "$ladder_missing" "wont-cover台帳が存在しない"

# --- export構造・値検証(fail-closed) ---
for case_spec in \
  'functions非配列|.data[0].functions = {}|functionsが配列でない' \
  'data空配列|.data = []|dataの要素数が1でない' \
  'data複数要素|.data += .data|dataの要素数が1でない' \
  'data非配列(object)|.data = {}|dataが配列でない' \
  'data非配列(文字列)|.data = "x"|dataが配列でない' \
  'data非配列(null)|.data = null|dataが配列でない' \
  'dataキー欠落|del(.data)|dataが配列でない' \
  'name欠落|del(.data[0].functions[1].name)|nameが欠落・空・非文字列' \
  'name非文字列|.data[0].functions[1].name = 5|nameが欠落・空・非文字列' \
  'filenames欠落|del(.data[0].functions[1].filenames)|filenamesが欠落・空・非配列' \
  'filenames空|.data[0].functions[1].filenames = []|filenamesが欠落・空・非配列' \
  'filenames非配列|.data[0].functions[1].filenames = "x"|filenamesが欠落・空・非配列' \
  'filenames相対パス|.data[0].functions[1].filenames = ["rel/B.swift"]|絶対パスでない' \
  'filenamesリポジトリ外|.data[0].functions[1].filenames = ["/elsewhere/B.swift"]|リポジトリ配下でない' \
  'regions欠落|del(.data[0].functions[1].regions)|regionsが欠落・非配列' \
  'regions非配列|.data[0].functions[1].regions = "x"|regionsが欠落・非配列' \
  'region要素数不足|.data[0].functions[1].regions = [[1,2,3,4]]|regionが不正' \
  'region要素非数値|.data[0].functions[1].regions = [[1,2,3,4,"0",0,0,0]]|regionが不正' \
  'execCount文字列|.data[0].functions[1].regions[0][4] = "0"|regionが不正' \
  'execCount負数|.data[0].functions[1].regions[0][4] = -1|regionが不正' \
  'execCount非整数|.data[0].functions[1].regions[0][4] = 0.5|regionが不正'; do
  IFS='|' read -r case_name mutation expected <<<"$case_spec"
  export_broken="$fixture_dir/export-broken.json"
  mutate_export "$export_broken" "$mutation"
  expect_fail "export$case_name" "$export_broken" "$ladder_empty" "$expected"
done

export_notjson="$fixture_dir/export-notjson.json"
printf '%s\n' "not json" >"$export_notjson"
expect_fail "exportパース不能" "$export_notjson" "$ladder_empty" "パースできない"

export_out_of_scope="$fixture_dir/export-out-of-scope.json"
mutate_export "$export_out_of_scope" '.data[0].functions |= [.[2]]'
expect_fail "スコープ0件" "$export_out_of_scope" "$ladder_empty" "一致する関数が0件"

export_zero_regions="$fixture_dir/export-zero-regions.json"
mutate_export "$export_zero_regions" '(.data[0].functions[0].regions, .data[0].functions[1].regions) = []'
expect_fail "総region数0" "$export_zero_regions" "$ladder_empty" "総region数が0件"

# --- measure: PATHスタブでfail-closedの伝播と成功経路argvを検証 ---
stub_bin="$fixture_dir/stubbin"
stub_artifacts="$fixture_dir/artifacts"
mkdir -p "$stub_bin" "$stub_artifacts/MimizukuCorePackageTests.xctest/Contents/MacOS" \
  "$stub_artifacts/codecov"
touch "$stub_artifacts/MimizukuCorePackageTests.xctest/Contents/MacOS/MimizukuCorePackageTests" \
  "$stub_artifacts/codecov/default.profdata"

cat >"$stub_bin/swift" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  test) exit "${STUB_SWIFT_TEST_STATUS:-0}" ;;
  build)
    if [[ ${STUB_SWIFT_BUILD_STATUS:-0} -ne 0 ]]; then exit "$STUB_SWIFT_BUILD_STATUS"; fi
    echo "$STUB_BIN_DIR"
    ;;
  *) exit 64 ;;
esac
EOF
cat >"$stub_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  llvm-cov)
    printf '%s\n' "$*" >"$STUB_LLVM_LOG"
    if [[ ${STUB_LLVM_STATUS:-0} -ne 0 ]]; then exit "$STUB_LLVM_STATUS"; fi
    cat "$STUB_EXPORT_JSON"
    ;;
  swift-demangle) cat ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$stub_bin/swift" "$stub_bin/xcrun"

run_measure() {
  PATH="$stub_bin:$PATH" \
    COVERAGE_SENSOR_ROOT="$fx_root" \
    COVERAGE_SENSOR_WONTCOVER="$ladder_empty" \
    STUB_BIN_DIR="$stub_artifacts" \
    STUB_LLVM_LOG="$fixture_dir/llvm-args.log" \
    STUB_EXPORT_JSON="$export_base" \
    "$@" bash "$sensor" 2>&1
}

expect_measure_fail() {
  local name=$1 expected=$2
  shift 2
  local output status
  set +e
  output=$(run_measure env "$@")
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo "coverage sensor test failed: $name: 失敗すべきところ成功した: $output" >&2
    exit 1
  }
  grep -Fq "$expected" <<<"$output" || {
    echo "coverage sensor test failed: $name: 「$expected」がない: $output" >&2
    exit 1
  }
  pass_count=$((pass_count + 1))
}

expect_measure_fail "measure: swift test失敗の伝播" "swift test --enable-code-coverage が失敗した" STUB_SWIFT_TEST_STATUS=1
expect_measure_fail "measure: show-bin-path失敗の伝播" "swift build --show-bin-path が失敗した" STUB_SWIFT_BUILD_STATUS=1
expect_measure_fail "measure: llvm-cov失敗の伝播" "llvm-cov export が失敗した" STUB_LLVM_STATUS=1

empty_dir="$fixture_dir/empty-artifacts"
mkdir -p "$empty_dir"
expect_measure_fail "measure: covered executable欠損" "covered executableが存在しない" STUB_BIN_DIR="$empty_dir"
no_prof_dir="$fixture_dir/no-prof-artifacts"
mkdir -p "$no_prof_dir/MimizukuCorePackageTests.xctest/Contents/MacOS"
touch "$no_prof_dir/MimizukuCorePackageTests.xctest/Contents/MacOS/MimizukuCorePackageTests"
expect_measure_fail "measure: profdata欠損" "profdataが存在しない" STUB_BIN_DIR="$no_prof_dir"

set +e
output=$(run_measure env)
status=$?
set -e
[[ $status -eq 0 ]] || {
  echo "coverage sensor test failed: measure成功経路: exit=$status output=$output" >&2
  exit 1
}
grep -Fq "$scope/B.swift" <<<"$output" || {
  echo "coverage sensor test failed: measure成功経路: analyzeへJSONが渡っていない: $output" >&2
  exit 1
}
expected_argv="llvm-cov export -format=text $stub_artifacts/MimizukuCorePackageTests.xctest/Contents/MacOS/MimizukuCorePackageTests -instr-profile=$stub_artifacts/codecov/default.profdata --sources Packages/MimizukuCore/Sources/MimizukuCore"
grep -Fxq "$expected_argv" "$fixture_dir/llvm-args.log" || {
  echo "coverage sensor test failed: measure成功経路: llvm-cov argvが期待列と一致しない: $(cat "$fixture_dir/llvm-args.log")" >&2
  exit 1
}
pass_count=$((pass_count + 2))

echo "coverage sensor tests passed ($pass_count cases)"
