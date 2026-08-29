#!/usr/bin/env bash
# カバレッジsensor(G-0013 決定1〜3)。set point =「sensor出力ゼロ」を機械判定する。
#
# 使い方:
#   coverage-sensor.sh            # measure: 計測ビルド + llvm-cov export + analyze(重い)
#   coverage-sensor.sh analyze <export.json>   # 解析のみ(実効テストが使う)
#
# 環境変数(実効テスト用の差し替え口):
#   COVERAGE_SENSOR_WONTCOVER  wont-cover台帳のパス(既定: scripts/coverage-wontcover.json)
#   COVERAGE_SENSOR_ROOT       パス正規化に使うリポジトリルート(既定: git rev-parse)
#
# fail-closed: 計測失敗・成果物欠損・export/台帳のschema違反・スコープ0件・総region 0件は
# すべて exit 1。検査不成立を pass にしない(G-0013 決定1・3)。
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

scope_prefix="Packages/MimizukuCore/Sources/MimizukuCore/"
package_path="Packages/MimizukuCore"

fail() {
  echo "coverage sensor failed: $1" >&2
  exit 1
}

analyze() {
  local export_json=$1
  local wontcover=${COVERAGE_SENSOR_WONTCOVER:-scripts/coverage-wontcover.json}
  # 正規化に使うルート。exportのfilenamesは絶対パスで、この配下でなければならない。
  local norm_root=${COVERAGE_SENSOR_ROOT:-$repo_root}

  [[ -f $export_json ]] || fail "export JSONが存在しない: $export_json"
  jq empty "$export_json" 2>/dev/null || fail "export JSONをパースできない: $export_json"
  [[ -f $wontcover ]] ||
    fail "wont-cover台帳が存在しない: $wontcover(空台帳は entries: [] で表現する)"
  jq empty "$wontcover" 2>/dev/null || fail "wont-cover台帳をパースできない: $wontcover"

  # 検証と集計を1パスのjqで行い、errors非空ならfail-closed。
  local result
  result=$(jq -n \
    --slurpfile export "$export_json" \
    --slurpfile ladder "$wontcover" \
    --arg root "$norm_root" \
    --arg scope "$scope_prefix" '
    ($export[0]) as $e |
    ($ladder[0]) as $l |
    ($root + "/") as $rootSlash |

    # --- export構造・値検証(台帳側と対称のfail-closed) ---
    ( [
        (if ($e | type) != "object" then "export: トップレベルがobjectでない" else empty end),
        (if ($e | type) == "object" and (($e.data? | type) != "array") then "export: dataが配列でない" else empty end),
        (if ($e.data? | type) == "array" and (($e.data | length) != 1) then "export: dataの要素数が1でない(\($e.data | length)件)" else empty end)
      ] ) as $envErrors |
    (if ($envErrors | length) > 0 then {errors: $envErrors} else
      ($e.data[0].functions?) as $fns |
      (if ($fns | type) != "array" then {errors: ["export: data[0].functionsが配列でない"]} else
        ( [ $fns[] as $f | (
            (if ($f | type) != "object" then "export: functionsの要素がobjectでない" else empty end),
            (if ($f | type) == "object" and (($f.name? | type) != "string" or $f.name == "") then "export: nameが欠落・空・非文字列: \($f.name? // "(欠落)" | tostring)" else empty end),
            (if ($f | type) == "object" and (($f.filenames? | type) != "array" or ($f.filenames | length) == 0) then "export: filenamesが欠落・空・非配列(name=\($f.name? // "?" | tostring))" else empty end),
            (if ($f.filenames? | type) == "array" and ($f.filenames | length) > 0 and (($f.filenames[0] | type) != "string" or ($f.filenames[0] | startswith("/") | not)) then "export: filenames[0]が絶対パスでない(name=\($f.name? // "?" | tostring))" else empty end),
            (if ($f.filenames? | type) == "array" and ($f.filenames | length) > 0 and (($f.filenames[0] | type) == "string") and ($f.filenames[0] | startswith("/")) and ($f.filenames[0] | startswith($rootSlash) | not) then "export: filenames[0]がリポジトリ配下でない: \($f.filenames[0])" else empty end),
            (if ($f | type) == "object" and (($f.regions? | type) != "array") then "export: regionsが欠落・非配列(name=\($f.name? // "?" | tostring))" else empty end),
            (if ($f.regions? | type) == "array" then
              ( [ $f.regions[] | select(
                    (type != "array") or (length < 5) or
                    (any(.[0:5][]; type != "number")) or
                    ((.[4] | type) == "number" and ((.[4] < 0) or (.[4] != (.[4] | floor))))
                  ) ] |
                if length > 0 then "export: regionが不正(要素5未満・非数値・execCountが負数か非整数)(name=\($f.name? // "?" | tostring))" else empty end )
            else empty end)
          ) ] ) as $fnErrors |
        (if ($fnErrors | length) > 0 then {errors: $fnErrors} else

          # --- スコープ(positive inclusion)と集計 ---
          ( [ $fns[] |
              . + {rel: (.filenames[0] | ltrimstr($rootSlash))} |
              select(.rel | startswith($scope)) |
              {name, rel,
               total: (.regions | length),
               uncovered: ([.regions[] | select(.[4] == 0)] | length),
               lines: ([.regions[] | select(.[4] == 0) | .[0]] | unique)}
            ] ) as $scoped |
          (if ($scoped | length) == 0 then {errors: ["スコープ(\($scope))に一致する関数が0件(vacuous pass拒否)"]} else
          (if ([ $scoped[].total ] | add) == 0 then {errors: ["スコープ内の総region数が0件(検査不成立)"]} else

          # --- 台帳のschema検証 ---
          ( [
              (if ($l | type) != "object" then "台帳: トップレベルがobjectでない" else empty end),
              (if ($l | type) == "object" and ($l.schemaVersion? != 1) then "台帳: schemaVersionが1でない" else empty end),
              (if ($l | type) == "object" and (($l.entries? | type) != "array") then "台帳: entriesが配列でない" else empty end)
            ] ) as $lEnvErrors |
          (if ($lEnvErrors | length) > 0 then {errors: $lEnvErrors} else
            ( [ $l.entries[] as $en | (
                (if ($en | type) != "object" then "台帳: entryがobjectでない" else empty end),
                (if ($en | type) == "object" and (($en.symbol? | type) != "string" or $en.symbol == "") then "台帳: symbolが欠落・空" else empty end),
                (if ($en | type) == "object" and (($en.file? | type) != "string" or $en.file == "") then "台帳: fileが欠落・空(symbol=\($en.symbol? // "?" | tostring))" else empty end),
                (if ($en.file? | type) == "string" and $en.file != "" and (($en.file | startswith("/")) or ($en.file | test("(^|/)\\.\\.(/|$)")) or ($en.file | startswith($scope) | not)) then "台帳: fileがルート相対のスコープ内パスでない: \($en.file)" else empty end),
                (if ($en | type) == "object" and (($en.reason? | type) != "string" or $en.reason == "") then "台帳: reasonが欠落・空(symbol=\($en.symbol? // "?" | tostring))" else empty end),
                (if ($en | type) == "object" and (($en.registeredRegions? | type) != "number" or $en.registeredRegions < 0 or ($en.registeredRegions != ($en.registeredRegions | floor))) then "台帳: registeredRegionsが非負整数でない(symbol=\($en.symbol? // "?" | tostring))" else empty end),
                (if ($en | type) == "object" and (($en.registeredUncovered? | type) != "number" or $en.registeredUncovered < 0 or ($en.registeredUncovered != ($en.registeredUncovered | floor))) then "台帳: registeredUncoveredが非負整数でない(symbol=\($en.symbol? // "?" | tostring))" else empty end)
              ) ] ) as $entryErrors |
            ( [ $l.entries[] | .symbol? ] | group_by(.) | map(select(length > 1) | .[0] | tostring) |
              map("台帳: symbolが重複: " + .) ) as $dupErrors |
            (if (($entryErrors + $dupErrors) | length) > 0 then {errors: ($entryErrors + $dupErrors)} else

              # --- 台帳照合(file+登録時実測の3点。不一致=失効 / stale・曖昧=エラー) ---
              ( [ $l.entries[] as $en |
                  ( [ $scoped[] | select(.name == $en.symbol) ] ) as $m |
                  (if ($m | length) == 0 then {error: ("台帳: symbolがスコープ内のexportに存在しない(stale): " + $en.symbol)}
                   elif ($m | length) > 1 then {error: ("台帳: symbolがexport内で複数に一致(曖昧): " + $en.symbol)}
                   elif ($m[0].rel != $en.file) then {expired: {symbol: $en.symbol, why: "file不一致(台帳=\($en.file) 実測=\($m[0].rel))"}}
                   elif ($m[0].total != $en.registeredRegions) then {expired: {symbol: $en.symbol, why: "region総数不一致(台帳=\($en.registeredRegions) 実測=\($m[0].total))"}}
                   elif ($m[0].uncovered != $en.registeredUncovered) then {expired: {symbol: $en.symbol, why: "未カバー数不一致(台帳=\($en.registeredUncovered) 実測=\($m[0].uncovered))"}}
                   else {valid: $en.symbol} end)
                ] ) as $checks |
              ( [ $checks[] | .error? | select(. != null) ] ) as $ladderErrors |
              (if ($ladderErrors | length) > 0 then {errors: $ladderErrors} else
                ( [ $checks[] | .valid? | select(. != null) ] ) as $validSymbols |
                ( [ $checks[] | .expired? | select(. != null) ] ) as $expired |
                ( [ $scoped[] | select(.uncovered > 0) | select(. as $s | $validSymbols | index($s.name) | not) ] ) as $out |
                {errors: [],
                 uncovered: $out,
                 expired: $expired,
                 summary: {scopedFunctions: ($scoped | length),
                           totalRegions: ([ $scoped[].total ] | add),
                           uncoveredFunctions: ($out | length),
                           uncoveredRegions: ([ $out[].uncovered ] | add // 0),
                           ladderValid: ($validSymbols | length),
                           ladderExpired: ($expired | length)}}
              end)
            end)
          end)
          end) end)
        end)
      end)
    end)
  ') || fail "解析(jq)が失敗した"

  local errors
  errors=$(jq -r '.errors[]?' <<<"$result")
  if [[ -n $errors ]]; then
    while IFS= read -r line; do echo "coverage sensor failed: $line" >&2; done <<<"$errors"
    exit 1
  fi

  # 失効・未カバーの人間可読出力(シンボルはdemangle表示、失敗時はmangledのまま)。
  jq -r '.expired[] | "expired: \(.symbol) — \(.why)"' <<<"$result"
  jq -r '.uncovered[] | "\(.rel)\t\(.name)\t\(.uncovered)/\(.total)\tlines:\(.lines | map(tostring) | join(","))"' <<<"$result" |
    while IFS=$'\t' read -r rel name counts lines; do
      local display
      display=$(printf '%s\n' "$name" | xcrun swift-demangle 2>/dev/null | head -1 || true)
      [[ -n $display ]] || display=$name
      printf '%s\t%s\t%s\t%s\n' "$rel" "$display" "$counts" "$lines"
    done

  jq -r '.summary | "summary: scoped_functions=\(.scopedFunctions) total_regions=\(.totalRegions) uncovered_functions=\(.uncoveredFunctions) uncovered_regions=\(.uncoveredRegions) wontcover_valid=\(.ladderValid) wontcover_expired=\(.ladderExpired)"' <<<"$result"
  if [[ $(jq -r '(.uncovered | length) + (.expired | length)' <<<"$result") -eq 0 ]]; then
    echo "set point reached: sensor出力ゼロ(G-0013 決定2)"
  fi
}

measure() {
  swift test --package-path "$package_path" --enable-code-coverage ||
    fail "swift test --enable-code-coverage が失敗した"

  local bin_dir
  bin_dir=$(swift build --package-path "$package_path" --show-bin-path | tail -1) ||
    fail "swift build --show-bin-path が失敗した"
  [[ -n $bin_dir ]] || fail "swift build --show-bin-path の出力が空"

  local executable="$bin_dir/MimizukuCorePackageTests.xctest/Contents/MacOS/MimizukuCorePackageTests"
  local profdata="$bin_dir/codecov/default.profdata"
  [[ -f $executable ]] || fail "covered executableが存在しない: $executable"
  [[ -f $profdata ]] || fail "profdataが存在しない: $profdata"

  local export_json
  export_json=$(mktemp "${TMPDIR:-/tmp}/coverage-export.XXXXXX")
  # 引数順は実測確定: executableが先でないとllvm-covは失敗する。--sourcesはADR決定1の
  # 字義とfiles節の限定のためで、functionsは絞られない(スコープ強制はanalyze側)。
  if ! xcrun llvm-cov export -format=text "$executable" -instr-profile="$profdata" \
    --sources "$package_path/Sources/MimizukuCore" >"$export_json"; then
    rm -f -- "$export_json"
    fail "llvm-cov export が失敗した"
  fi
  analyze "$export_json"
  rm -f -- "$export_json"
}

case "${1:-measure}" in
  measure) measure ;;
  analyze)
    [[ $# -ge 2 ]] || fail "analyzeにはexport JSONのパスが必要"
    analyze "$2"
    ;;
  *) fail "不明なサブコマンド: $1(measure | analyze <export.json>)" ;;
esac
