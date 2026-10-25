#!/bin/zsh
# Compiles the engine with Tools/selftest.swift and runs it on a fake hyperlapse.
#   ./Tools/selftest.sh [dossier de sortie]
set -e
ROOT=${0:A:h:h}
OUT="$ROOT/.build/selftest"
mkdir -p "$OUT"
swiftc -O -swift-version 5 -parse-as-library -target $(uname -m)-apple-macosx14.0 \
  "$ROOT"/Sources/{Geometry,ImageLoader,Tracker,Renderer,MatchCut,Shapes,Stabilizer,Project}.swift \
  "$ROOT/Tools/selftest.swift" -o "$OUT/selftest"
rm -f "$OUT/session.json"
HYPERLAPSE_SESSION="$OUT/session.json" "$OUT/selftest" "${1:-$OUT}"
