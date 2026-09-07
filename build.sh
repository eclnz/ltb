#!/usr/bin/env bash
# Build and test the ltb commands.
#
#   ./build.sh                headless CLI + windowed viewer, optimised
#   ./build.sh debug          both, with debug info, bounds checks and ASan
#   ./build.sh headless       just the CLI (links no graphics libraries)
#   ./build.sh check          type-check and vet every package without linking
#   ./build.sh test           run every package's tests
#   ./build.sh test hex geo   run just these packages' tests
#
# Tests run one package at a time. A package is compiled with its dependencies
# and nothing else, so testing `hex` does not build raylib, the renderer or the
# viewer -- which is the point of keeping the graph layered.
set -euo pipefail

cd "$(dirname "$0")"
ODIN=${ODIN:-odin}
COLLECTION="-collection:ltb=$PWD/src"
OUT=build
mkdir -p "$OUT"

# Every package, leaves first, so a failure surfaces at the lowest layer that
# caused it rather than in whatever imported it.
PACKAGES="hex geo ecs layers world ingest/tiff ingest sim ui render app"

# Static checks. Kept in one place so `check` and `test` cannot drift apart from
# each other on what counts as acceptable code.
#
#   -vet-unused        bindings and imports nothing reads
#   -vet-shadowing     an inner declaration hiding an outer one
#   -vet-using-stmt    `using` at statement level, which makes scope unreadable
#   -vet-semicolon     stray terminators
#   -vet-cast          casts that do nothing
#   -strict-style      the compiler's own formatting and import-ordering rules
#
# Deliberately not -vet-style: it rejects the aligned struct field blocks and
# tabular @(rodata) tables this codebase uses on purpose.
VET="-vet-unused -vet-shadowing -vet-using-stmt -vet-semicolon -vet-cast -strict-style"

# Address and undefined-behaviour sanitizers, on the debug build only. The
# layers package hands out raw slices into mmap'd chunk storage, so an
# out-of-bounds write there is otherwise silent until the data looks wrong.
SANITIZE="-sanitize:address"

mode=${1:-release}
case "$mode" in
  release)  FLAGS="-o:speed" ;;
  debug)    FLAGS="-debug -o:none $SANITIZE $VET" ;;
  headless) FLAGS="-o:speed" ;;
  test)     FLAGS="$VET" ;;
  check)    FLAGS="$VET" ;;
  *) echo "usage: $0 [release|debug|headless|check|test [package...]]" >&2; exit 2 ;;
esac

case "$mode" in
  test)
    shift
    selected=${*:-}
    failed=0
    if [ -n "$selected" ]; then
      # A package named on the command line and holding no tests is a mistake
      # worth reporting, not something to skip past quietly.
      for pkg in $selected; do
        dir="src/$pkg"
        if [ ! -d "$dir" ]; then
          echo "no package src/$pkg" >&2
          exit 2
        fi
        if ! compgen -G "$dir/*_test.odin" > /dev/null; then
          echo "src/$pkg has no *_test.odin" >&2
          exit 2
        fi
      done
      list="$selected"
    else
      list="$PACKAGES"
    fi

    for pkg in $list; do
      dir="src/$pkg"
      if ! compgen -G "$dir/*_test.odin" > /dev/null; then
        echo "---- $pkg: no tests"
        continue
      fi
      echo "---- $pkg"
      if ! $ODIN test "$dir" $COLLECTION $FLAGS -out:"$OUT/test-${pkg//\//-}"; then
        failed=$((failed + 1))
      fi
    done
    exit $failed
    ;;
  check)
    for pkg in $PACKAGES; do
      echo "checking src/$pkg"
      $ODIN check "src/$pkg" $COLLECTION $FLAGS -no-entry-point
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
