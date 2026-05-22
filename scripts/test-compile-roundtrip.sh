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
#   ubuntu-version  ubuntu-latest
#
# Steps:
#   1. Runs nlp.exe interpreted on the input file and saves the resulting
#      <input>_log/final.tree as <analyzer-dir>/final.interpreted.tree.
#   2. Compiles the analyzer to a native .so via compile-analyzer.sh.
#   3. Runs nlp.exe -COMPILED on the same input file.
#   4. Byte-for-byte compares the two final.tree files.
#
# Exits 0 on match, 1 on mismatch (or any failure along the way).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ANALYZER_ARG="${1:-$REPO_ROOT/analyzer-templates/Date and Times}"
INPUT_ARG="${2:-}"
UBUNTU="${3:-ubuntu-latest}"

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

NLP_EXE="$REPO_ROOT/$UBUNTU/nlp.exe"
if [ ! -x "$NLP_EXE" ]; then
  echo "ERROR: nlp.exe not found or not executable at $NLP_EXE" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$REPO_ROOT/$UBUNTU:${LD_LIBRARY_PATH:-}"

INPUT_LEAF="$(basename "$INPUT_FILE")"
INPUT_DIR="$(dirname "$INPUT_FILE")"
LOG_DIR="$INPUT_DIR/${INPUT_LEAF}_log"
FINAL_TREE="$LOG_DIR/final.tree"

# Saved interpreted-run tree lives in the analyzer dir (alongside the .so), so
# it isn't clobbered when LOG_DIR is cleaned between runs.
SAVED_TREE="$ANALYZER_DIR/final.interpreted.tree"

run_nlp() {
  local stage="$1"
  local compiled="${2:-}"

  rm -rf "$LOG_DIR"

  local -a args=()
  if [ "$compiled" = "compiled" ]; then
    args+=(-COMPILED)
  fi
  args+=(-ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE")

  echo "==> [$stage] $NLP_EXE ${args[*]}"
  "$NLP_EXE" "${args[@]}"

  if [ ! -f "$FINAL_TREE" ]; then
    echo "ERROR: expected $FINAL_TREE was not produced by the $stage run" >&2
    exit 1
  fi
}

echo "Analyzer : $ANALYZER_DIR"
echo "Input    : $INPUT_FILE"
echo "Log dir  : $LOG_DIR"
echo

# --- 1. Interpreted run -----------------------------------------------------
run_nlp 'interpreted'
cp -f "$FINAL_TREE" "$SAVED_TREE"
echo "    Saved interpreted tree -> $SAVED_TREE"
echo

# --- 2. Compile analyzer ----------------------------------------------------
echo "==> [compile] scripts/compile-analyzer.sh"
"$(dirname "$0")/compile-analyzer.sh" "$ANALYZER_DIR" "$INPUT_FILE" "$UBUNTU"

DLL="$ANALYZER_DIR/bin/kb.so"
if [ ! -f "$DLL" ]; then
  echo "ERROR: expected compiled library not found: $DLL" >&2
  exit 1
fi
echo

# --- 3. Compiled run --------------------------------------------------------
run_nlp 'compiled' 'compiled'
echo

# --- 4. Compare -------------------------------------------------------------
echo "==> [diff] $SAVED_TREE  <-->  $FINAL_TREE"

if cmp -s "$SAVED_TREE" "$FINAL_TREE"; then
  hash="$(sha256sum "$SAVED_TREE" | awk '{print $1}')"
  echo
  echo "PASS: interpreted and compiled final.tree are byte-identical."
  echo "      sha256: $hash"
  exit 0
fi

hashA="$(sha256sum "$SAVED_TREE"  | awk '{print $1}')"
hashB="$(sha256sum "$FINAL_TREE"  | awk '{print $1}')"

echo
echo "FAIL: interpreted and compiled final.tree differ."
echo "      interpreted sha256: $hashA"
echo "      compiled    sha256: $hashB"
echo
echo "First differing lines (< interpreted, > compiled):"
diff "$SAVED_TREE" "$FINAL_TREE" | head -n 40 || true
total_diff="$(diff "$SAVED_TREE" "$FINAL_TREE" | wc -l)"
if [ "$total_diff" -gt 40 ]; then
  echo "  ... ($((total_diff - 40)) more diff lines)"
fi

exit 1
