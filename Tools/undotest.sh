#!/bin/zsh
# Compiles the model with Tools/undotest.swift and runs it on the self-test photos (./Tools/selftest.sh first).
set -e
ROOT=${0:A:h:h}
OUT="$ROOT/.build/undotest"
mkdir -p "$OUT"
swiftc -O -swift-version 5 -parse-as-library -target $(uname -m)-apple-macosx14.0 \
  "$ROOT"/Sources/{Geometry,ImageLoader,Tracker,Renderer,MatchCut,Project}.swift "$ROOT/Tools/undotest.swift" -o "$OUT/undotest"
rm -f "$OUT/session.json"
HYPERLAPSE_SESSION="$OUT/session.json" "$OUT/undotest" "$ROOT/.build/selftest/hyperlapse-selftest"
