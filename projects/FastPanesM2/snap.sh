#!/usr/bin/env bash
# Headless self-drive + timestamped PNG capture of FastPanesM2.
# Drops a marker file so the exe runs its SelfTest (show -> type -> build -> snap x3
# -> exit) instead of the interactive loop, then archives the PNGs under
# projects/FastPanesM2/snaps/<timestamp>/ so runs never overwrite each other.
# Usage (from anywhere):  bash projects/FastPanesM2/snap.sh
set -u
cd "$(dirname "$0")/../.."                      # repo root
PROJ=projects/FastPanesM2
EXE=$PROJ/FastPanesM2.exe
TS=$(date +%Y%m%d_%H%M%S)
DIR=$PROJ/snaps/$TS
mkdir -p "$DIR"
echo drive > "$PROJ/fastpanes_drive.txt"
rm -f "$PROJ"/snap1_initial.png "$PROJ"/snap2_ast.png "$PROJ"/snap3_errors.png "$PROJ"/snap4_undo.png "$PROJ"/snap5_redo.png
timeout 40 "$EXE"; echo "(run exit $?)"
rm -f "$PROJ/fastpanes_drive.txt"
cp "$PROJ/snap1_initial.png" "$DIR/01_initial.png" 2>/dev/null
cp "$PROJ/snap2_ast.png"     "$DIR/02_ast.png"     2>/dev/null
cp "$PROJ/snap3_errors.png"  "$DIR/03_errors.png"  2>/dev/null
cp "$PROJ/snap4_undo.png"    "$DIR/04_undo.png"    2>/dev/null
cp "$PROJ/snap5_redo.png"    "$DIR/05_redo.png"    2>/dev/null
echo "snaps -> $DIR"; ls "$DIR" 2>/dev/null
