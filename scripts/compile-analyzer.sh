#!/usr/bin/env bash
#
# compile-analyzer.sh — Compile an NLP++ analyzer into the native shared
# libraries that the -COMPILED engine dlopens at runtime.
#
# Usage:
#   scripts/compile-analyzer.sh [--kb-only] <analyzer-dir> <input-file> [ubuntu-version]
#
# Example:
#   scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt
#   scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt ubuntu-22.04
#   scripts/compile-analyzer.sh --kb-only data/rfb data/rfb/input/text.txt
#
# Produces (default, full-analyzer mode):
#   <analyzer-dir>/bin/run.so
#   <analyzer-dir>/bin/runu.so
#   <analyzer-dir>/bin/kb.so
#   <analyzer-dir>/bin/kbu.so
#
# Produces (--kb-only):
#   <analyzer-dir>/bin/kb.so
#   <analyzer-dir>/bin/kbu.so
#
# How it fits into the runtime (engine v3.1.44+):
#   - `nlp -COMPILE` emits the analyzer C++ trees:
#       <analyzer-dir>/run/pass*.cpp  + analyzer.h / ehead.h / rhead.h / data.h
#       <analyzer-dir>/kb/Sym*.cpp / Con*.cpp / Ptr*.cpp / St*.cpp + Cc_code.cpp
#     (or `nlp -COMPILEKB` for just kb/ when --kb-only).
#   - This script wraps those trees with an auto-generated StdAfx.h stub and
#     builds them into a single SHARED library via cmake.
#   - The resulting library exports both `run_analyzer(Parse*)` and
#     `kb_setup(void*)` (the engine codegen emits both — see lite/seqn.cpp
#     and consh/cc_gen.cpp).
#   - The library is staged into <analyzer-dir>/bin/ under the names the
#     engine's load_compiled() (lite/nlp.cpp:1242) and consh's KB loader
#     (cs/libconsh/cg.cpp:168) look for: bin/run.<ext> / bin/runu.<ext> /
#     bin/kb.<ext> / bin/kbu.<ext>.
#
# Linker handling mirrors what nlp-compile-service's emit-cmake.sh does for
# the cloud build, since the same engine compile-libs are linked here:
#   - -DLINUX: the engine's public headers take the LINUX branch
#     (my_tchar.h's _TCHAR typedef, no Windows __declspec).
#   - PREFIX "": cmake's default `lib` prefix on SHARED targets is
#     suppressed so the output filename is <name>.so, matching what the
#     engine and extension expect.
#   - -Wl,--whole-archive around ICU: virtual-class typeinfo
#     (e.g. icu::ByteSink) must always end up in the .so even if no
#     analyzer-side code references it directly. Without this dlopen
#     fails at runtime with "undefined symbol: _ZTIN6icu_788ByteSinkE".
#   - -Wl,--start-group ... --end-group around the engine static libs:
#     forces ld to re-scan archives until all cross-archive references
#     (e.g. CG::addWord defined in libconsh.a, referenced from liblite.a)
#     resolve. Without this the .so links with undefined symbols that
#     break at dlopen time.

set -euo pipefail

KB_ONLY=false
while [ "${1:-}" = "--kb-only" ]; do
  KB_ONLY=true
  shift
done

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 [--kb-only] <analyzer-dir> <input-file> [ubuntu-version]" >&2
  exit 64
fi

ANALYZER_ARG="$1"
INPUT_FILE="$2"
UBUNTU="${3:-ubuntu-latest}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZER_DIR="$(cd "$ANALYZER_ARG" && pwd)"

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

if [ "$KB_ONLY" = "true" ]; then
  COMPILE_FLAG="-COMPILEKB"
  TARGET_NAME="nlp_kb"
  SRC_GLOB="kb"
else
  COMPILE_FLAG="-COMPILE"
  TARGET_NAME="nlp_analyzer"
  SRC_GLOB="run|kb"
fi

echo "==> [1/3] nlp.exe $COMPILE_FLAG  (emits .cpp trees under $ANALYZER_DIR/{$SRC_GLOB}/)"
"$NLP_EXE" "$COMPILE_FLAG" -ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE"

BUILD_ROOT="$ANALYZER_DIR/.nlp-compile"
SRC_DIR="$BUILD_ROOT/src"
BUILD_DIR="$BUILD_ROOT/build"
rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_DIR"

# Engine-generated .cpp files begin with `#include "StdAfx.h"`; cmake also
# force-includes this file. Same stub the cloud writes.
cat > "$SRC_DIR/StdAfx.h" <<'EOF'
#pragma once
#include "my_tchar.h"
EOF

# Engine static libs. The cmake template uses --start-group below to
# re-scan, so order isn't sensitive. ICU link order is significant
# (i18n -> uc -> data) but moot under --whole-archive.
ENGINE_LIB_NAMES="prim kbm consh words lite"
ICU_LIB_NAMES="icui18n icuuc icudata"

if [ "$KB_ONLY" = "true" ]; then
  GLOB_LINES="file(GLOB GENERATED_CPP \"$ANALYZER_DIR/kb/*.cpp\")"
else
  GLOB_LINES="file(GLOB GENERATED_CPP \"$ANALYZER_DIR/run/*.cpp\" \"$ANALYZER_DIR/kb/*.cpp\")"
fi

echo "==> [2/3] Generate CMakeLists.txt"
cat > "$SRC_DIR/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(${TARGET_NAME}_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Engine public headers gate Windows-only constructs on #ifndef LINUX;
# define LINUX so the right branches activate.
add_compile_definitions(LINUX)

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$ANALYZER_DIR/bin")

$GLOB_LINES
if(NOT GENERATED_CPP)
  message(FATAL_ERROR "No generated .cpp files found — did $COMPILE_FLAG succeed?")
endif()

add_library($TARGET_NAME SHARED \${GENERATED_CPP})

# Suppress cmake's default 'lib' prefix on SHARED targets so the output
# filename matches what the engine's load_compiled() looks for.
set_target_properties($TARGET_NAME PROPERTIES
  OUTPUT_NAME "$TARGET_NAME"
  PREFIX ""
)

target_include_directories($TARGET_NAME PRIVATE
  "$SRC_DIR"
  "$ANALYZER_DIR"
  "$ANALYZER_DIR/run"
  "$ANALYZER_DIR/kb"
  "$COMPILE_LIBS/include/Api"
  "$COMPILE_LIBS/include/cs"
)

target_compile_options($TARGET_NAME PRIVATE -include StdAfx.h)
target_link_directories($TARGET_NAME PRIVATE "$COMPILE_LIBS/lib")

# Engine static libs wrapped in --start-group so ld re-scans until cross-
# archive references resolve (e.g. CG::addWord lives in libconsh.a but is
# referenced from liblite.a).
target_link_libraries($TARGET_NAME PRIVATE
  -Wl,--start-group
  $ENGINE_LIB_NAMES
  -Wl,--end-group
)

# ICU static libs force-linked in full so virtual-class typeinfo
# (icu::ByteSink etc.) is always emitted into the .so. Without this,
# dlopen fails with undefined-symbol errors at runtime.
target_link_libraries($TARGET_NAME PRIVATE
  -Wl,--whole-archive
  $ICU_LIB_NAMES
  -Wl,--no-whole-archive
)

find_library(DL_LIBRARY dl)
if(DL_LIBRARY)
  target_link_libraries($TARGET_NAME PRIVATE \${DL_LIBRARY})
endif()
EOF

echo "==> [3/3] cmake configure + build (Release)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --config Release

OUT="$ANALYZER_DIR/bin/${TARGET_NAME}.so"
if [ ! -f "$OUT" ]; then
  echo "ERROR: expected output $OUT was not produced" >&2
  exit 1
fi

# Stage the built library under every name the engine's load paths look
# for (lite/nlp.cpp:1242 / cs/libconsh/cg.cpp:168). The "u" variants are
# the UNICODE build flavour; copying them keeps both engine flavours
# happy without a rebuild.
echo "==> Staging $(basename "$OUT") into $ANALYZER_DIR/bin/"
if [ "$KB_ONLY" = "true" ]; then
  cp -f "$OUT" "$ANALYZER_DIR/bin/kb.so"
  cp -f "$OUT" "$ANALYZER_DIR/bin/kbu.so"
  STAGED="bin/kb.so bin/kbu.so"
else
  cp -f "$OUT" "$ANALYZER_DIR/bin/run.so"
  cp -f "$OUT" "$ANALYZER_DIR/bin/runu.so"
  cp -f "$OUT" "$ANALYZER_DIR/bin/kb.so"
  cp -f "$OUT" "$ANALYZER_DIR/bin/kbu.so"
  STAGED="bin/run.so bin/runu.so bin/kb.so bin/kbu.so"
fi

echo
echo "Built: $OUT"
echo "Staged: $STAGED"
echo "Run:    $NLP_EXE -COMPILED -ANA $ANALYZER_DIR -WORK $REPO_ROOT $INPUT_FILE"
