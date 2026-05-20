#!/usr/bin/env bash
#
# compile-analyzer.sh — Compile an NLP++ analyzer (and its KB) to a native
# shared library that nlp.exe can load with -COMPILED.
#
# Usage:
#   scripts/compile-analyzer.sh <analyzer-dir> <input-file> [ubuntu-version]
#
# Example:
#   scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt
#   scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt ubuntu-22.04
#
# Produces: <analyzer-dir>/<analyzer-name>.so
# Run it with: <ubuntu-version>/nlp.exe -COMPILED -ANA <analyzer-dir> -WORK . <input>

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <analyzer-dir> <input-file> [ubuntu-version]" >&2
  exit 64
fi

ANALYZER_ARG="$1"
INPUT_FILE="$2"
UBUNTU="${3:-ubuntu-latest}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZER_DIR="$(cd "$ANALYZER_ARG" && pwd)"
ANALYZER_NAME="$(basename "$ANALYZER_DIR")"

NLP_EXE="$REPO_ROOT/$UBUNTU/nlp.exe"
COMPILE_LIBS="$REPO_ROOT/compile-libs/$UBUNTU"

if [ ! -x "$NLP_EXE" ]; then
  echo "ERROR: nlp.exe not found or not executable at $NLP_EXE" >&2
  exit 1
fi
if [ ! -d "$COMPILE_LIBS/include" ] || [ ! -d "$COMPILE_LIBS/lib" ]; then
  echo "ERROR: compile libraries not found at $COMPILE_LIBS" >&2
  echo "Expected: compile-libs/$UBUNTU/{include,lib}" >&2
  echo "(The workflow .github/workflows/nlp-engine-build.yml drops these in place." >&2
  echo " If they are missing, the upstream release may not yet attach the linux" >&2
  echo " compile-libs zip — re-run the workflow once it does, or fetch them" >&2
  echo " manually from a successful upstream build-linux.yml run.)" >&2
  exit 1
fi
if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: input file not found: $INPUT_FILE" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$REPO_ROOT/$UBUNTU:${LD_LIBRARY_PATH:-}"

echo "==> [1/3] nlp.exe -COMPILE  (emits run/*.cpp and kb/*.cpp under $ANALYZER_DIR)"
"$NLP_EXE" -COMPILE -ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE"

BUILD_ROOT="$ANALYZER_DIR/.nlp-compile"
SRC_DIR="$BUILD_ROOT/src"
BUILD_DIR="$BUILD_ROOT/build"
rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_DIR"

# Generated engine sources expect to find StdAfx.h on the include path.
cat > "$SRC_DIR/StdAfx.h" <<'EOF'
#pragma once
#include "my_tchar.h"
EOF

echo "==> [2/3] Generate CMakeLists.txt"
cat > "$SRC_DIR/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(nlp_generated_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$ANALYZER_DIR")

file(GLOB GENERATED_CPP
  "$ANALYZER_DIR/run/*.cpp"
  "$ANALYZER_DIR/kb/*.cpp"
)
if(NOT GENERATED_CPP)
  message(FATAL_ERROR "No generated .cpp files found under $ANALYZER_DIR/{run,kb}/ — did -COMPILE succeed?")
endif()

add_library(nlp_generated SHARED \${GENERATED_CPP})
set_target_properties(nlp_generated PROPERTIES OUTPUT_NAME "$ANALYZER_NAME")

target_include_directories(nlp_generated PRIVATE
  "$SRC_DIR"
  "$ANALYZER_DIR"
  "$ANALYZER_DIR/run"
  "$ANALYZER_DIR/kb"
  "$COMPILE_LIBS/include/Api"
  "$COMPILE_LIBS/include/cs"
)

target_compile_options(nlp_generated PRIVATE -include StdAfx.h)
target_link_directories(nlp_generated PRIVATE "$COMPILE_LIBS/lib")

# Engine static libs (link order matters: prim is base; others depend on it).
# ICU link order is also significant: i18n -> uc -> data.
target_link_libraries(nlp_generated PRIVATE
  prim kbm consh words lite
  icui18n icuuc icudata
)

find_library(DL_LIBRARY dl)
if(DL_LIBRARY)
  target_link_libraries(nlp_generated PRIVATE \${DL_LIBRARY})
endif()
EOF

echo "==> [3/3] cmake configure + build"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --config Release

OUT="$ANALYZER_DIR/${ANALYZER_NAME}.so"
if [ -f "$OUT" ]; then
  echo
  echo "Built: $OUT"
  echo "Run:   $NLP_EXE -COMPILED -ANA $ANALYZER_DIR -WORK $REPO_ROOT $INPUT_FILE"
else
  echo "ERROR: expected output $OUT was not produced" >&2
  exit 1
fi
