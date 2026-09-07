#!/usr/bin/env bash
# Build the ltb commands.
#
#   ./build.sh            headless CLI + windowed viewer, optimised
#   ./build.sh debug      both, with debug info and bounds checks
#   ./build.sh headless   just the CLI (links no graphics libraries)
#   ./build.sh test       run the test suite
#   ./build.sh check      type-check every package without linking
set -euo pipefail

cd "$(dirname "$0")"
ODIN=${ODIN:-odin}
COLLECTION="-collection:ltb=$PWD/src"
OUT=build
mkdir -p "$OUT"

mode=${1:-release}
case "$mode" in
  release)  FLAGS="-o:speed" ;;
  debug)    FLAGS="-debug -o:none" ;;
  headless) FLAGS="-o:speed" ;;
  test)     FLAGS="" ;;
  check)    FLAGS="" ;;
  *) echo "usage: $0 [release|debug|headless|test|check]" >&2; exit 2 ;;
esac

case "$mode" in
  test)
    $ODIN test tests $COLLECTION -out:"$OUT/tests"
    ;;
  check)
    for pkg in src/hex src/geo src/layers src/world src/ingest src/sim src/render src/app; do
      echo "checking $pkg"
      $ODIN check "$pkg" $COLLECTION -no-entry-point
    done
    ;;
  headless)
    $ODIN build src/cmd/ltb $COLLECTION $FLAGS -out:"$OUT/ltb"
    echo "built $OUT/ltb"
    ;;
  *)
    $ODIN build src/cmd/ltb $COLLECTION $FLAGS -out:"$OUT/ltb"
    echo "built $OUT/ltb"
    $ODIN build src/cmd/ltb-view $COLLECTION $FLAGS -out:"$OUT/ltb-view"
    echo "built $OUT/ltb-view"
    ;;
esac
