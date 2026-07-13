#!/usr/bin/env bash
#
# mayhem/build.sh — build microsoft/bond's `bf` fuzz target + the full C++ test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# exports the build contract: CC/CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS, SRC.
#
# Bond's code generator `gbc` is a Haskell program; building it needs a full GHC/stack
# toolchain. The Dockerfile bakes a prebuilt Linux gbc (built from this repo's compiler/
# tree at release 13.0.1, which is byte-identical to the tip's compiler/) at
# /opt/bond-gbc/gbc, and we point CMake at it via BOND_GBC_PATH — so this script needs no
# network and no Haskell toolchain (air-gapped re-run, SPEC §6.5).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# rapidjson is a git submodule; the CI build context ships gitlinks only. Materialize it
# once at image-build time (guarded — the offline in-image re-run skips this, keeping
# build.sh air-gapped on the already-built tree).
if [ ! -e "$SRC/thirdparty/rapidjson/include/rapidjson/rapidjson.h" ]; then
  git -C "$SRC" submodule update --init thirdparty/rapidjson
fi

GBC=/opt/bond-gbc/gbc
[ -x "$GBC" ] || { echo "prebuilt gbc missing at $GBC (Dockerfile bug)" >&2; exit 1; }

# Bond hard-codes `--std=c++11 -Wall -Werror` via add_compile_options (which lands AFTER
# CMAKE_CXX_FLAGS on the command line), and clang 19 + boost 1.83 trip warnings this
# 2015-era codebase never saw. The wrappers append trailing flags so the LAST word wins:
# C++14 (boost 1.83's minimum) and no -Werror. Upstream files stay untouched (additive).
CXX_WRAP="$SRC/mayhem/clang++-wrapper.sh"
CC_WRAP="$SRC/mayhem/clang-wrapper.sh"
chmod +x "$CXX_WRAP" "$CC_WRAP"

common_args=(
  -DCMAKE_C_COMPILER="$CC_WRAP"
  -DCMAKE_CXX_COMPILER="$CXX_WRAP"
  -DBOND_GBC_PATH="$GBC"
  -DBOND_SKIP_GBC_TESTS=TRUE
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

# 1) Sanitized fuzz build: the bond core library + the `bf` transcoder (the fuzz target)
#    are compiled with ASan+UBSan (halting) + DWARF-3, so the *fuzzed code* is instrumented.
#    ONE narrow UBSan relax: `enum` — bf's job is protocol-guessing arbitrary bytes, so
#    "load of invalid value for BondDataType" fires on virtually every input (e.g.
#    fast_binary.h reading a wire byte into the enum) and would abort before any
#    exploration. ASan + the rest of UBSan stay on and halting.
FUZZ_SAN="$SANITIZER_FLAGS"
[ -n "$FUZZ_SAN" ] && FUZZ_SAN="$FUZZ_SAN -fno-sanitize=enum"
cmake -B "$SRC/build" -S "$SRC" "${common_args[@]}" \
      -DCMAKE_C_FLAGS="$FUZZ_SAN $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$FUZZ_SAN $DEBUG_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$FUZZ_SAN"
cmake --build "$SRC/build" -j"$MAYHEM_JOBS" --target bf
install -m 755 "$SRC/build/examples/cpp/core/bf/bf" /mayhem/bf

# 2) Test-suite build with the project's NORMAL flags (independent tree; test.sh only RUNS it).
#    Bond's ctest suite (unit tests, compat round-trips, bf golden transcodes, examples) is
#    EXCLUDE_FROM_ALL, so after `all` we build every remaining Makefile target explicitly.
#    Two example targets cannot compile against boost 1.83 / libstdc++-14 (upstream is
#    archived, written for ~boost 1.6x): `multiprecision` (boost.multiprecision numbers no
#    longer look like containers to bond's traits) and `scoped_alloc` (std::scoped_allocator
#    constructor requirements). They are skipped here and in mayhem/test.sh (counted as
#    skipped in the CTRF summary).
cmake -B "$SRC/build-tests" -S "$SRC" "${common_args[@]}" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
      -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
test_targets=$(cmake --build "$SRC/build-tests" --target help 2>/dev/null \
  | sed -n 's/^\.\.\. \([^ ]*\).*/\1/p' \
  | grep -vxE 'all|clean|depend|help|test|check|install|install/local|install/strip|list_install_components|edit_cache|rebuild_cache|package|package_source|multiprecision|scoped_alloc')
# shellcheck disable=SC2086
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" $(printf -- '--target %s ' $test_targets)

echo "build.sh: done (bf + test suite built)"
