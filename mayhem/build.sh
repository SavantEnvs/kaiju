#!/usr/bin/env bash
#
# mayhem/build.sh — build the Kaiju fuzz target and the functional test suite.
#
# Fuzz target: `mkbwt` (Kaiju's BWT/suffix-array index builder — historical Mayhem
# target). It's a file-input CLI: it reads a FASTA file and builds the BWT, so the
# instrumented binary IS the harness (no libFuzzer wrapper needed). The whole tool is
# built with $SANITIZER_FLAGS + $DEBUG_FLAGS so the fuzzed code (readFasta / suffixArray
# / multikeyqsort) is instrumented and carries DWARF < 4 symbols.
#
# Test suite: the project's real binaries (kaiju-mkbwt, kaiju-mkfmi, kaiju) built with
# the project's NORMAL flags, so mayhem/test.sh only RUNS a deterministic known-answer
# classification pipeline (see test.sh). Kept independent of the sanitized build above.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX

cd "$SRC"

# ---------------------------------------------------------------------------
# 1) Fuzz target: instrumented mkbwt -> /mayhem/mkbwt
#    Compiled+linked in one clang invocation (no .o left in the source tree, so it
#    doesn't collide with the normal test build below). mkbwt allocates-and-exits by
#    design (batch tool), which the leak checker would otherwise flag on every input —
#    but the sanitizer runtime option set belongs to Mayhem alone (never a compiled-in
#    default-options override, and never a Mayhemfile-level override): Mayhem's own
#    run configuration owns that, so none is baked in here.
#    $DEBUG_FLAGS goes AFTER $SANITIZER_FLAGS so its -gdwarf-3 wins over the base's -g.
# ---------------------------------------------------------------------------
BWT="$SRC/src/bwt"
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -pthread \
  -I"$BWT" \
  "$BWT/mkbwt.c" "$BWT/readFasta.c" "$BWT/suffixArray.c" \
  "$BWT/multikeyqsort.c" "$BWT/sequence.c" \
  -lm -o /mayhem/mkbwt

# ---------------------------------------------------------------------------
# 2) Test suite: the project's own binaries, NORMAL flags (clean, uninstrumented).
#    `make` (default `all`) builds every Kaiju tool and copies them into ../bin,
#    including bin/kaiju-mkbwt, bin/kaiju-mkfmi and bin/kaiju that test.sh drives.
# ---------------------------------------------------------------------------
make -C "$SRC/src" -j"$MAYHEM_JOBS" CC="$CC" CXX="$CXX"

test -x "$SRC/bin/kaiju"        || { echo "build.sh: bin/kaiju missing" >&2; exit 1; }
test -x "$SRC/bin/kaiju-mkbwt"  || { echo "build.sh: bin/kaiju-mkbwt missing" >&2; exit 1; }
test -x "$SRC/bin/kaiju-mkfmi"  || { echo "build.sh: bin/kaiju-mkfmi missing" >&2; exit 1; }

echo "build.sh: OK — /mayhem/mkbwt (fuzz) + bin/ test tools built"
