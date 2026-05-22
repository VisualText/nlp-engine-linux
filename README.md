# NLP Engine for Linux

This repository packages the [VisualText NLP Engine](https://github.com/VisualText/nlp-engine) (`nlp.exe`) as a ready-to-run binary distribution for Linux. It mirrors the latest release from the upstream `VisualText/nlp-engine` repository, rebuilds it for multiple Ubuntu targets, and ships the binaries together with the supporting data files and a small Python wrapper.

If you just want the Linux executable to run NLP++ analyzers on your machine, this is the repository you want.

## Companion Repositories

The NLP Engine is distributed per platform. Pick the one that matches your OS:

| Platform | Repository |
|----------|------------|
| Linux    | [VisualText/nlp-engine-linux](https://github.com/VisualText/nlp-engine-linux) (this repo) |
| Windows  | [VisualText/nlp-engine-windows](https://github.com/VisualText/nlp-engine-windows) |
| macOS    | [VisualText/nlp-engine-mac](https://github.com/VisualText/nlp-engine-mac) |
| Source   | [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) |

For production use from Python, prefer the [NLPPlus Python package](https://github.com/VisualText/py-package-nlpengine) instead of the simple wrapper shipped here.

## Repository Layout

```
nlp-engine-linux/
├── .github/workflows/
│   └── nlp-engine-build.yml      GitHub Action that mirrors upstream releases
├── .gitmodules                   declares the `python/` submodule
├── .version-flag                 timestamp + tag of the last sync
├── data/
│   └── rfb/                      "rules file builder" analyzer (NLP++ spec files)
│       └── spec/
│           ├── analyzer.seq      sequence of passes for this analyzer
│           ├── *.nlp             individual NLP++ passes
│           └── ...
├── python/                       submodule: simple Python wrapper for nlp.exe
│   ├── nlpengine.py              `NLPEngine` class (subprocess wrapper)
│   └── genHtmlHighlights.py      example: generate HTML highlights for analyzer output
├── scripts/
│   └── compile-analyzer.sh       compile the analyzer's KB into bin/kb.so
└── README.md
```

After the GitHub Action runs, the workflow also drops the following into the repository root (these are not committed in the source tree on disk during normal development, but appear on the released revisions):

- `nlp.exe` — the engine binary
- `ubuntu-20.04/`, `ubuntu-22.04/`, `ubuntu-latest/` — per-distribution binaries plus the unpacked `icu-libs` shared libraries
- `compile-libs/ubuntu-20.04/`, `compile-libs/ubuntu-22.04/`, `compile-libs/ubuntu-latest/` — headers and static libraries used by the compile scripts to link a compiled analyzer/KB
- `data/` — runtime data shipped with the engine

## How the Release Workflow Works

The workflow defined in [.github/workflows/nlp-engine-build.yml](.github/workflows/nlp-engine-build.yml) keeps this repository in lock-step with releases of the upstream engine.

It runs on two triggers:

1. **`repository_dispatch`** of type `nlp-engine-release` — fired by the upstream `VisualText/nlp-engine` repository when it cuts a new release.
2. **`workflow_dispatch`** — a manual button in the Actions tab. Useful for forcing a rebuild against the latest (or a specific) upstream tag.

When triggered, the job:

1. Looks up the upstream release tag (from the dispatch payload, manual input, or `getLatestRelease` as a fallback).
2. Skips the run if a git tag with that name already exists in this repository — unless the trigger was manual.
3. Downloads four assets from the upstream release:
   - `ubuntu-20.04.zip`
   - `ubuntu-22.04.zip`
   - `ubuntu-latest.zip`
   - `nlpengine.zip` (engine data + analyzer specs)
4. Unpacks each Ubuntu zip into `ubuntu-<version>/`, renames `nlpl.exe` → `nlp.exe`, and extracts the bundled `icu-libs.zip`.
5. Unpacks `nlpengine.zip` to the repository root so the `data/` tree is refreshed.
6. `git rm`'s the previous binary set in a dedicated commit ("Remove old binary files before update to ..."), then commits the new binaries ("Update NLP Engine files to latest release ...").
7. Tags the new commit with the upstream version (e.g. `v3.1.9`) and publishes a matching GitHub Release.

The two-commit pattern (remove, then update) is intentional: it keeps the diff readable and ensures git notices the binary churn even when filenames are unchanged. You can see the pattern in the recent history:

```
e0161e7 Update NLP Engine files to latest release v3.1.9
e4a654f Remove old binary files before update to v3.1.9
dea8552 Update NLP Engine files to latest release v3.1.8
60dac47 Remove old binary files before update to v3.1.8
```

The current upstream version that this repository tracks is recorded in [.version-flag](.version-flag).

## Using the Engine

### 1. Get a build

Clone the repository, or download a release tarball from the [Releases page](https://github.com/VisualText/nlp-engine-linux/releases). Pick the directory that matches your distribution:

- `ubuntu-20.04/` — Ubuntu 20.04 LTS
- `ubuntu-22.04/` — Ubuntu 22.04 LTS
- `ubuntu-latest/` — newest Ubuntu the GitHub runner offers (currently 24.04)

Each directory contains `nlp.exe` plus the ICU shared libraries it links against. If your distro's system `libicu` matches, you can use the system libraries directly; otherwise add the bundled ones to your loader path:

```bash
export LD_LIBRARY_PATH="$PWD/ubuntu-22.04:$LD_LIBRARY_PATH"
```

### 2. Run an analyzer from the command line

`nlp.exe` takes three pieces of information: where the engine lives (`-WORK`), which analyzer to run (`-ANA`), and the input file to feed it (positional). To run the `rfb` analyzer shipped in `data/` against `input/text.txt`:

```bash
./ubuntu-22.04/nlp.exe \
  -ANA  data/rfb \
  -WORK . \
  data/rfb/input/text.txt
```

Add `-DEV` to keep the per-pass `.tree` and `.kbb` log files under `<input>_log/` for inspection.

### 3. Drive it from Python

The `python/` submodule wraps the subprocess call. Initialize it (you have to clone with `--recurse-submodules` to get it):

```bash
git clone --recurse-submodules https://github.com/VisualText/nlp-engine-linux.git
```

Then in your script:

```python
from python.nlpengine import NLPEngine

nlp = NLPEngine(engineDir=".", analyzersDir="data")
nlp.analyzeInput("rfb", "text.txt", dev=True)
```

`NLPEngine` provides a handful of helpers:

| Method | Purpose |
|--------|---------|
| `analyzeInput(folder, textPath, dev=False)` | Run an analyzer over a file in its `input/` directory. Clears stale log directories first. |
| `isAnalyzerFolder(folder)` | True if `folder` contains the required `spec/`, `input/`, and `kb/user/` subtrees. |
| `clearLogFiles(folder)` | Remove every `*_log/` directory under the analyzer's `input/`. |
| `createInputDir(analyzer, sub, clearFolder=True)` | Create (and optionally wipe) an input subdirectory. |
| `analyzerPath` / `kbPath` / `specPath` / `inputTextLog` | Convenience path builders. |

[python/genHtmlHighlights.py](python/genHtmlHighlights.py) is a fuller example that runs an analyzer, then runs four "colorizer" analyzers over the result to emit syntax-highlighted HTML for the `.tree`, `.nlp`, `.dict`, and `.kbb` files.

### 4. Compile an analyzer's KB to a native shared library

By default `nlp.exe` runs analyzers fully interpreted. With the new `EMBEDED_KB`-enabled engine, the **knowledge base** can be compiled to a native shared library that the engine `dlopen`s at `-COMPILED` time and calls into via a single exported `kb_setup` symbol. (Analyzer pass code itself is still interpreted — upstream removed `ana_gen` in 1999, so there is no compiled-rules path; the engine falls back to interpreted execution for the rules.)

| Script | What it does | Output |
|--------|--------------|--------|
| [scripts/compile-analyzer.sh](scripts/compile-analyzer.sh) | Runs `nlp.exe -COMPILE` (emits `Cc_code.cpp` plus the `Sym*.cpp` / `Con*.cpp` / `Ptr*.cpp` / `St*.cpp` tables under `<analyzer>/kb/`), generates a one-line `kb_setup()` shim, and links everything into a single SHARED library against the per-Ubuntu `compile-libs/`. Only `kb_setup` is exported (`-fvisibility=hidden` everywhere else). | `<analyzer>/bin/kb.so` |

Prerequisites: `cmake` ≥ 3.16 and a C++17-capable `g++`. On Ubuntu:

```bash
sudo apt install build-essential cmake
```

Usage:

```bash
# Compile the bundled rfb analyzer's KB (defaults to ubuntu-latest binaries):
./scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt

# Pin a specific Ubuntu variant:
./scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt ubuntu-22.04

# Run with the compiled KB (rules stay interpreted, KB is dlopen'd):
LD_LIBRARY_PATH="$PWD/ubuntu-22.04:$LD_LIBRARY_PATH" \
  ./ubuntu-22.04/nlp.exe -COMPILED -ANA data/rfb -WORK . data/rfb/input/text.txt
```

What you should see in the `-COMPILED` output for a successful round-trip:

```
[CG: Trying to load compiled KB.]
[Loading compiled kb: data/rfb/bin/kb.so]
[Loaded compiled kb library]
[Loading compiled analyzer ...]
[Error: Couldn't load compiled analyzer.]      # expected — no run.so exists
[No compiled analyzer; falling back to interpreted.]
... normal parse output ...
```

The compile-libs come from upstream's `nlpengine-compile-libs-linux-<ubuntu-ver>.zip` — the release workflow drops them into `compile-libs/ubuntu-<version>/{include,lib}/` alongside the runtime binaries.

> **Note:** Ubuntu 20.04 ships dynamic ICU (`libicu*.so.66`) rather than static `libicu*.a`. If linking fails on the 20.04 variant, `sudo apt install libicu-dev` provides the development symlinks the linker needs.

## The `data/rfb` Analyzer

`rfb` ("rules file builder") is an NLP++ analyzer included so that this repository works end-to-end out of the box. Its [spec/analyzer.seq](data/rfb/spec/analyzer.seq) lists the passes the engine runs over an input, and each `*.nlp` file in [data/rfb/spec/](data/rfb/spec/) implements one pass. Useful entry points if you want to read it:

- `tokenize` / `bigtok.nlp` — initial tokenization
- `decl.nlp`, `decls.nlp` — handle NLP++ declarations
- `rule.nlp`, `rules.nlp`, `rulesfile.nlp` — parse the rule structure itself
- `gram1.nlp` … `gram5.nlp` — grammar passes
- `actions.nlp`, `preaction.nlp`, `posts.nlp` — semantic actions
- `finalerr.nlp` — error reporting at the end of the run

If you are new to NLP++, the upstream [VisualText documentation](https://visualtext.org) and the [VisualText VS Code extension](https://marketplace.visualstudio.com/items?itemName=dehilster.nlp) are the best starting points.

## Versioning

Releases of this repository track the upstream engine version exactly. A release tagged `v3.1.9` here contains the Linux binaries built from `VisualText/nlp-engine` at `v3.1.9`. See [.version-flag](.version-flag) for the current pinned tag, and the [Releases page](https://github.com/VisualText/nlp-engine-linux/releases) for the full history.

## Contributing

Source-level changes to the engine itself belong in [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine); they will flow into this repository automatically on the next release. Open issues or PRs against *this* repo for:

- Problems specific to the Linux packaging (missing libraries, wrong paths, broken Ubuntu version targets).
- Improvements to the build workflow in [.github/workflows/nlp-engine-build.yml](.github/workflows/nlp-engine-build.yml).
- Fixes or examples for the Python wrapper (note that `python/` is a submodule — PRs land in [VisualText/python](https://github.com/VisualText/python)).

## License

The NLP Engine and its supporting files are distributed under the license set by the upstream [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) repository. Refer to that repository for the authoritative LICENSE file.
