#!/usr/bin/env bash
# Assemble a self-contained FastPanesM2 release into ./release (repo root).
# Prereqs: cargo build -p newm2-driver  &&  newm2-driver build projects/FastPanesM2/FastPanesM2.mod
# The IDE finds everything relative to its own exe, so the folder is relocatable.
set -eu
cd "$(dirname "$0")/../.."                 # repo root
REL=release
rm -rf "$REL"; mkdir -p "$REL"
cp projects/FastPanesM2/FastPanesM2.exe "$REL/"
cp target/debug/newm2-driver.exe        "$REL/"
cp -r library                           "$REL/library"
cp projects/FastPanesM2/sample.mod      "$REL/"
cp projects/FastPanesM2/cmpl_demo.mod   "$REL/"
cp projects/FastPanesM2/RELEASE.md      "$REL/README.txt"
echo "release/ assembled ($(du -sh "$REL" | cut -f1)):"
ls -1 "$REL"
