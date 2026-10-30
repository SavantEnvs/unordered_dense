#!/usr/bin/env bash
#
# mayhem/build.sh — build the six libFuzzer targets (+ standalone reproducers) and the unit suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# unordered_dense is header-only, so "the project" is the translation unit that includes
# include/ankerl/unordered_dense.h: each fuzz target below is upstream's own test/unit/fuzz_*.cpp
# compiled with -DFUZZ (upstream's switch from a doctest case to LLVMFuzzerTestOneInput), with the
# sanitizer + DWARF-3 + SanCov flags. fmt and doctest come from apt -dev packages (Dockerfile).
TARGETS="fuzz_api fuzz_group_index fuzz_index_view fuzz_insert_erase fuzz_replace_map fuzz_string"
BUILD="$SRC/builddir"                       # gitignored upstream, so `git clean -ffdX` removes it
mkdir -p "$BUILD/fuzz" "$BUILD/test"

COMMON="-std=c++17 -I$SRC/include -I$SRC/test -isystem /usr/include/doctest -DFMT_HEADER_ONLY \
  -DANKERL_UNORDERED_DENSE_HAS_BOOST=0 -DDOCTEST_COUNTER=__COUNTER__"
FUZZ_DEFS="-DFUZZ -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DDOCTEST_CONFIG_DISABLE -O2"
SANCOV="-fsanitize=fuzzer-no-link"

# Compile one translation unit: $1=src $2=obj, remaining args are extra flags.
cc_one() {
  local src="$1" obj="$2"; shift 2
  # shellcheck disable=SC2086
  $CXX $COMMON $FUZZ_DEFS $SANITIZER_FLAGS $DEBUG_FLAGS "$@" -c "$src" -o "$obj"
}

# 1+2) sanitized fuzz binaries + standalone reproducers. The fuzz object carries SanCov instrumentation
# (fuzzer-no-link) even when SANITIZER_FLAGS is empty; the standalone object does not need it.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/fuzz/standalone_main.o"
cc_one "$SRC/mayhem/lsan_off.cc" "$BUILD/fuzz/lsan_off.o"
cc_one "$SRC/test/app/counter.cpp" "$BUILD/fuzz/counter_fuzz.o" $SANCOV
cc_one "$SRC/test/app/counter.cpp" "$BUILD/fuzz/counter_sa.o"

build_target() {
  local t="$1"
  cc_one "$SRC/test/unit/$t.cpp" "$BUILD/fuzz/$t.o" $SANCOV
  cc_one "$SRC/test/unit/$t.cpp" "$BUILD/fuzz/$t.sa.o"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/fuzz/$t.o" "$BUILD/fuzz/counter_fuzz.o" \
      "$BUILD/fuzz/lsan_off.o" -o "$SRC/$t"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/fuzz/$t.sa.o" "$BUILD/fuzz/counter_sa.o" "$BUILD/fuzz/lsan_off.o" \
      "$BUILD/fuzz/standalone_main.o" -o "$SRC/$t-standalone"
}
export -f cc_one build_target
export CXX CC COMMON FUZZ_DEFS SANCOV SANITIZER_FLAGS DEBUG_FLAGS LIB_FUZZING_ENGINE SRC BUILD
echo $TARGETS | tr ' ' '\n' | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'set -e; build_target {}'

# 3) the project's unit suite (doctest), NORMAL flags: no sanitizer, no DWARF pin, no coverage unless asked.
#    The source list is upstream's own (test/meson.build test_sources).
SOURCES=$(grep -v '^[[:space:]]*#' test/meson.build | grep -oE "'(app|bench|fuzz|unit)/[A-Za-z0-9_/]+\.cpp'" | tr -d "'" | sort -u)
objs=()
compile_test() {
  local rel="$1" obj="$BUILD/test/$(echo "$1" | tr / _).o"
  # shellcheck disable=SC2086
  $CXX $COMMON -O1 -g0 $COVERAGE_FLAGS -pthread -c "$SRC/test/$rel" -o "$obj"
}
export -f compile_test
export CXX COMMON COVERAGE_FLAGS SRC BUILD
echo "$SOURCES" | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'set -e; compile_test {}'
for rel in $SOURCES; do objs+=("$BUILD/test/$(echo "$rel" | tr / _).o"); done
# shellcheck disable=SC2086
$CXX $COVERAGE_FLAGS -pthread "${objs[@]}" -o "$BUILD/udm-test"
