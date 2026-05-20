#!/usr/bin/env bash
#
# compile-kb.sh — Compile only an analyzer's KB (knowledge base) to a native
# shared library. Use when the analyzer rules have not changed but the KB has.
#
# Usage:
#   scripts/compile-kb.sh <analyzer-dir> <input-file> [ubuntu-version]
#
# Example:
#   scripts/compile-kb.sh data/rfb data/rfb/input/text.txt
#   scripts/compile-kb.sh data/rfb data/rfb/input/text.txt ubuntu-22.04
#
# Produces: <analyzer-dir>/<analyzer-name>_kb.so

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
KB_LIB_NAME="${ANALYZER_NAME}_kb"

NLP_EXE="$REPO_ROOT/$UBUNTU/nlp.exe"
COMPILE_LIBS="$REPO_ROOT/compile-libs/$UBUNTU"

if [ ! -x "$NLP_EXE" ]; then
  echo "ERROR: nlp.exe not found or not executable at $NLP_EXE" >&2
  exit 1
fi
if [ ! -d "$COMPILE_LIBS/include" ] || [ ! -d "$COMPILE_LIBS/lib" ]; then
  echo "ERROR: compile libraries not found at $COMPILE_LIBS" >&2
  echo "Expected: compile-libs/$UBUNTU/{include,lib}" >&2
  exit 1
fi
if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: input file not found: $INPUT_FILE" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$REPO_ROOT/$UBUNTU:${LD_LIBRARY_PATH:-}"

echo "==> [1/3] nlp.exe -COMPILEKB  (emits kb/*.cpp under $ANALYZER_DIR)"
"$NLP_EXE" -COMPILEKB -ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE"

BUILD_ROOT="$ANALYZER_DIR/.nlp-compile-kb"
SRC_DIR="$BUILD_ROOT/src"
BUILD_DIR="$BUILD_ROOT/build"
rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_DIR"

cat > "$SRC_DIR/StdAfx.h" <<'EOF'
#pragma once
#include "my_tchar.h"
EOF

echo "==> [2/3] Generate CMakeLists.txt"
cat > "$SRC_DIR/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(nlp_generated_kb_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$ANALYZER_DIR")

file(GLOB GENERATED_CPP "$ANALYZER_DIR/kb/*.cpp")
if(NOT GENERATED_CPP)
  message(FATAL_ERROR "No generated .cpp files found under $ANALYZER_DIR/kb/ — did -COMPILEKB succeed?")
endif()

add_library(nlp_kb_generated SHARED \${GENERATED_CPP})
set_target_properties(nlp_kb_generated PROPERTIES OUTPUT_NAME "$KB_LIB_NAME")

target_include_directories(nlp_kb_generated PRIVATE
  "$SRC_DIR"
  "$ANALYZER_DIR"
  "$ANALYZER_DIR/kb"
  "$COMPILE_LIBS/include/Api"
  "$COMPILE_LIBS/include/cs"
)

target_compile_options(nlp_kb_generated PRIVATE -include StdAfx.h)
target_link_directories(nlp_kb_generated PRIVATE "$COMPILE_LIBS/lib")

target_link_libraries(nlp_kb_generated PRIVATE
  prim kbm consh words lite
  icui18n icuuc icudata
)

find_library(DL_LIBRARY dl)
if(DL_LIBRARY)
  target_link_libraries(nlp_kb_generated PRIVATE \${DL_LIBRARY})
endif()
EOF

echo "==> [3/3] cmake configure + build"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --config Release

OUT="$ANALYZER_DIR/${KB_LIB_NAME}.so"
if [ -f "$OUT" ]; then
  echo
  echo "Built: $OUT"
else
  echo "ERROR: expected output $OUT was not produced" >&2
  exit 1
fi
