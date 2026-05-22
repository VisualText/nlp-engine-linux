#!/usr/bin/env bash
#
# test-compile-roundtrip.sh — Verify that a compiled analyzer produces the same
# final.tree as the interpreted run.
#
# Usage:
#   scripts/test-compile-roundtrip.sh [analyzer-dir] [input-file] [ubuntu-version]
#
# Defaults:
#   analyzer-dir    analyzer-templates/Date and Times
#   input-file      <analyzer-dir>/input/test.txt
#   ubuntu-version  (auto-detect: every ubuntu-*/ folder at the repo root that
#                   contains nlp.exe; the roundtrip runs once per engine)
#
# Steps (per engine):
#   1. Runs nlp.exe interpreted on the input file and saves the resulting
#      <input>_log/final.tree as <analyzer-dir>/final.interpreted.tree.
#   2. Compiles the analyzer to a native .so via compile-analyzer.sh.
#   3. Runs nlp.exe -COMPILED on the same input file.
#   4. Byte-for-byte compares the two final.tree files.
#
# Exits 0 if every engine passes, 1 if any mismatch or failure occurs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ANALYZER_ARG="${1:-$REPO_ROOT/analyzer-templates/Date and Times}"
INPUT_ARG="${2:-}"
UBUNTU_ARG="${3:-}"

if [ ! -d "$ANALYZER_ARG" ]; then
  echo "ERROR: analyzer directory not found: $ANALYZER_ARG" >&2
  exit 1
fi
ANALYZER_DIR="$(cd "$ANALYZER_ARG" && pwd)"

if [ -z "$INPUT_ARG" ]; then
  INPUT_ARG="$ANALYZER_DIR/input/test.txt"
fi
if [ ! -f "$INPUT_ARG" ]; then
  echo "ERROR: input file not found: $INPUT_ARG" >&2
  exit 1
fi
INPUT_FILE="$(cd "$(dirname "$INPUT_ARG")" && pwd)/$(basename "$INPUT_ARG")"

# Build the list of engine folders to test.
UBUNTU_VERSIONS=()
if [ -n "$UBUNTU_ARG" ]; then
  UBUNTU_VERSIONS=("$UBUNTU_ARG")
else
  for d in "$REPO_ROOT"/ubuntu-*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ -x "$d/nlp.exe" ]; then
      UBUNTU_VERSIONS+=("$name")
    fi
  done
fi

if [ "${#UBUNTU_VERSIONS[@]}" -eq 0 ]; then
  echo "ERROR: no ubuntu-*/ engine folders with nlp.exe found under $REPO_ROOT" >&2
  exit 1
fi

INPUT_LEAF="$(basename "$INPUT_FILE")"
INPUT_DIR="$(dirname "$INPUT_FILE")"
LOG_DIR="$INPUT_DIR/${INPUT_LEAF}_log"
FINAL_TREE="$LOG_DIR/final.tree"

# Saved interpreted-run tree lives in the analyzer dir (alongside the .so), so
# it isn't clobbered when LOG_DIR is cleaned between runs.
SAVED_TREE="$ANALYZER_DIR/final.interpreted.tree"

run_nlp() {
  local nlp_exe="$1"
  local stage="$2"
  local compiled="${3:-}"

  rm -rf "$LOG_DIR"

  local -a args=()
  if [ "$compiled" = "compiled" ]; then
    args+=(-COMPILED)
  fi
  args+=(-ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE")

  echo "==> [$stage] $nlp_exe ${args[*]}"
  "$nlp_exe" "${args[@]}"

  if [ ! -f "$FINAL_TREE" ]; then
    echo "ERROR: expected $FINAL_TREE was not produced by the $stage run" >&2
    return 1
  fi
}

run_roundtrip() {
  local ubuntu="$1"
  local nlp_exe="$REPO_ROOT/$ubuntu/nlp.exe"

  if [ ! -x "$nlp_exe" ]; then
    echo "ERROR: nlp.exe not found or not executable at $nlp_exe" >&2
    return 1
  fi

  export LD_LIBRARY_PATH="$REPO_ROOT/$ubuntu:${LD_LIBRARY_PATH:-}"

  echo "============================================================"
  echo "Engine   : $ubuntu"
  echo "Analyzer : $ANALYZER_DIR"
  echo "Input    : $INPUT_FILE"
  echo "Log dir  : $LOG_DIR"
  echo "============================================================"
  echo

  # --- 1. Interpreted run ---------------------------------------------------
  run_nlp "$nlp_exe" 'interpreted'
  cp -f "$FINAL_TREE" "$SAVED_TREE"
  echo "    Saved interpreted tree -> $SAVED_TREE"
  echo

  # --- 2. Compile analyzer --------------------------------------------------
  echo "==> [compile] scripts/compile-analyzer.sh"
  "$(dirname "$0")/compile-analyzer.sh" "$ANALYZER_DIR" "$INPUT_FILE" "$ubuntu"

  local dll="$ANALYZER_DIR/bin/kb.so"
  if [ ! -f "$dll" ]; then
    echo "ERROR: expected compiled library not found: $dll" >&2
    return 1
  fi
  echo

  # --- 3. Compiled run ------------------------------------------------------
  run_nlp "$nlp_exe" 'compiled' 'compiled'
  echo

  # --- 4. Compare -----------------------------------------------------------
  echo "==> [diff] $SAVED_TREE  <-->  $FINAL_TREE"

  if cmp -s "$SAVED_TREE" "$FINAL_TREE"; then
    local hash
    hash="$(sha256sum "$SAVED_TREE" | awk '{print $1}')"
    echo
    echo "PASS [$ubuntu]: interpreted and compiled final.tree are byte-identical."
    echo "      sha256: $hash"
    return 0
  fi

  local hashA hashB
  hashA="$(sha256sum "$SAVED_TREE"  | awk '{print $1}')"
  hashB="$(sha256sum "$FINAL_TREE"  | awk '{print $1}')"

  echo
  echo "FAIL [$ubuntu]: interpreted and compiled final.tree differ."
  echo "      interpreted sha256: $hashA"
  echo "      compiled    sha256: $hashB"
  echo
  echo "First differing lines (< interpreted, > compiled):"
  diff "$SAVED_TREE" "$FINAL_TREE" | head -n 40 || true
  local total_diff
  total_diff="$(diff "$SAVED_TREE" "$FINAL_TREE" | wc -l)"
  if [ "$total_diff" -gt 40 ]; then
    echo "  ... ($((total_diff - 40)) more diff lines)"
  fi
  return 1
}

echo "Engines to test: ${UBUNTU_VERSIONS[*]}"
echo

PASSED=()
FAILED=()
for ubuntu in "${UBUNTU_VERSIONS[@]}"; do
  if run_roundtrip "$ubuntu"; then
    PASSED+=("$ubuntu")
  else
    FAILED+=("$ubuntu")
  fi
  echo
done

echo "============================================================"
echo "Summary"
echo "============================================================"
if [ "${#PASSED[@]}" -gt 0 ]; then
  echo "PASS: ${PASSED[*]}"
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "FAIL: ${FAILED[*]}"
  exit 1
fi
exit 0
