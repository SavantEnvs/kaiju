#!/usr/bin/env bash
#
# mayhem/test.sh — deterministic known-answer functional test for the Kaiju pipeline.
#
# NOTE ON PROVENANCE (tests_found): Kaiju's upstream CI (.github/workflows/ci.yaml) is a
# single functional demo — kaiju-makedb -s viruses (downloads live viral genomes from NCBI)
# + a SARS-CoV-2 classification that git-clones pmenzel/kaiju-testdata. It is network- and
# live-DB-dependent and therefore non-deterministic and not air-gappable, so it cannot serve
# as an RL oracle. This file is an AUTHORED behavioral known-answer test that exercises the
# same code path (kaiju-mkbwt -> kaiju-mkfmi -> kaiju) fully offline with asserted outputs:
# it builds a tiny protein database (via the fuzz target's own BWT/FM-index builders) and
# asserts that Kaiju classifies known reads to the expected NCBI taxon ids. A no-op / exit(0)
# patch of any tool breaks index construction or classification and FAILS this test.
#
# Contract: RUN only (build.sh already built bin/); assert BEHAVIOR; emit a CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BIN="$SRC/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

for t in kaiju kaiju-mkbwt kaiju-mkfmi; do
  [ -x "$BIN/$t" ] || { echo "test.sh: $BIN/$t missing (build.sh bug)" >&2; emit_ctrf "kaiju-kat" 0 1; exit 1; }
done

PASS=0; FAIL=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; PASS=$((PASS+1))
  else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=$((FAIL+1)); fi
}

cd "$WORK"

# Reference database: two proteins, each tagged with a distinct NCBI taxon id in the
# header (kaiju reads the taxon id after the final underscore).
cat > proteins.faa <<'EOF'
>protA_11111
MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQAPILSRVGDGTQDNLSGAEKAVQVKVKALPDAQFEVVHSLAKWKR
>protB_22222
MSDNKKLQVANFEHGVLIHDIAKTHFGRLSEEEKQAFLDLMHDVDPTLAWKHVGEHTQFADALFVSDEAGHYQWLKENV
EOF

cat > nodes.dmp <<'EOF'
1	|	1	|	no rank	|
11111	|	1	|	species	|
22222	|	1	|	species	|
EOF

# Build the index using the project's real tools (the fuzz target's BWT/FM-index code).
"$BIN/kaiju-mkbwt" -n 1 -l 1 -a ACDEFGHIKLMNPQRSTVWY -o kaiju_db proteins.faa >mkbwt.log 2>&1
"$BIN/kaiju-mkfmi" kaiju_db >mkfmi.log 2>&1
if [ -s kaiju_db.fmi ]; then echo "ok   - index build (kaiju-mkbwt + kaiju-mkfmi)"; PASS=$((PASS+1))
else echo "FAIL - index build produced no kaiju_db.fmi"; FAIL=$((FAIL+1)); fi

# Reads: exact substrings of each reference protein, plus one unrelated peptide.
cat > reads.faa <<'EOF'
>readA
AYIAKQRQISFVKSHFSRQLEER
>readB
NFEHGVLIHDIAKTHFGRLSEEEKQAFLDLM
>readN
WWWWWWWWWWWWWWWWWWWWWWWWWWWW
EOF

classify() { # <readname>  -> prints "flag taxon"
  awk -v r="$1" '$2==r {print $1" "$3}' out.tsv
}

if [ -s kaiju_db.fmi ]; then
  "$BIN/kaiju" -p -t nodes.dmp -f kaiju_db.fmi -i reads.faa -o out.tsv >kaiju.log 2>&1
  check "classify readA -> taxon 11111 (protA)" "C 11111" "$(classify readA)"
  check "classify readB -> taxon 22222 (protB)" "C 22222" "$(classify readB)"
  check "classify readN -> unclassified"        "U 0"     "$(classify readN)"
else
  echo "FAIL - classification skipped: no index"; FAIL=$((FAIL+3))
fi

emit_ctrf "kaiju-kat" "$PASS" "$FAIL"
