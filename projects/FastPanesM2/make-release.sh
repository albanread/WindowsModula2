#!/usr/bin/env bash
# Assemble a self-contained FastPanesM2 release into ./release (repo root).
# Prereq: cargo build -p newm2-driver   (and close any running FastPanesM2/daemon).
# The IDE finds everything relative to its own exe, so the folder is relocatable.
set -eu
cd "$(dirname "$0")/../.."                 # repo root
REL=release
rm -rf "$REL"; mkdir -p "$REL"
# Build the IDE with its DPI-aware manifest EMBEDDED into the exe (modern themed
# controls + DPI awareness baked in — no loose side-by-side .manifest to ship).
# Build straight into the release folder so a running dev instance can't lock it.
./target/debug/newm2-driver.exe build projects/FastPanesM2/FastPanesM2.mod \
  --library library --out "$REL/FastPanesM2.exe" \
  --manifest projects/FastPanesM2/FastPanesM2.exe.manifest
rm -f "$REL/FastPanesM2.obj"                      # drop the linker's sibling object
cp target/debug/newm2-driver.exe                 "$REL/"
cp -r library                           "$REL/library"
cp -r docs/m2-guide                     "$REL/help"        # the help pane's static docs
cp projects/FastPanesM2/sample.mod      "$REL/"
cp projects/FastPanesM2/cmpl_demo.mod   "$REL/"
cp projects/FastPanesM2/RELEASE.md      "$REL/README.txt"
echo "release/ assembled ($(du -sh "$REL" | cut -f1)):"
ls -1 "$REL"
