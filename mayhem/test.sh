#!/usr/bin/env bash
#
# mayhem/test.sh — RUN bond's own C++ test suite (built by mayhem/build.sh in build-tests/).
# The suite is upstream's full ctest set: Boost.Test unit tests, cross-protocol compat
# round-trips (deserialize + compare against golden data), bf golden transcodes, gbc
# schema checks, and the example programs — behavioral, not exit-0-only.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -d "$SRC/build-tests" ] || { echo "build-tests/ missing — mayhem/build.sh must run first" >&2; emit_ctrf cmake-ctest 0 1; exit 1; }

# Suite = upstream's full ctest set (79 tests found). Two example tests are excluded
# because their binaries cannot compile against boost 1.83 / libstdc++-14 (see
# mayhem/build.sh): multiprecision, scoped_alloc — counted below as skipped.
EXCLUDED=2
log=/tmp/ctest.log
( cd "$SRC/build-tests" && ctest --output-on-failure -j"$MAYHEM_JOBS" -E '^(multiprecision|scoped_alloc)$' ) | tee "$log"
rc=${PIPESTATUS[0]}

# ctest summary: "100% tests passed, 0 tests failed out of 79"
total=$(sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\2/p' "$log" | tail -1)
failed=$(sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\1/p' "$log" | tail -1)
run_skipped=$(grep -cE '\*\*\*Skipped' "$log" || true)
if [ -z "$total" ] || [ -z "$failed" ]; then
  echo "could not parse ctest summary" >&2
  emit_ctrf cmake-ctest 0 1
  exit 1
fi
passed=$(( total - failed - run_skipped ))
skipped=$(( run_skipped + EXCLUDED ))

# Output-assertion check on top of the suite: transcode the compat schema with the
# normally-built bf and require the known JSON content — asserts real program OUTPUT
# (ctest's checks are largely exit-code based), so a neutered exit(0) binary fails here.
total=$(( total + 1 ))
bf_out=$("$SRC/build-tests/examples/cpp/core/bf/bf" "$SRC/test/compat/core/data/compat.schema.dat" 2>/dev/null || true)
if [[ "$bf_out" == *'"unittest.compat.Compat"'* ]]; then
  echo "bf_output_json: Passed"
  passed=$(( passed + 1 ))
else
  echo "bf_output_json: FAILED (bf produced no/unexpected JSON for compat.schema.dat)"
  failed=$(( failed + 1 ))
fi
emit_ctrf cmake-ctest "$passed" "$failed" "$skipped"
exit_code=$?
[ "$rc" -eq 0 ] || exit_code=1
exit "$exit_code"
