#!/usr/bin/env bash
# get_mimalloc.sh - fetch mimalloc (Microsoft's allocator for many small objects, MIT licence) at a
# pinned release. uvm/build_board.sh compiles it into the testbench program (src/static.c, one
# file) in place of the C library's malloc: UVM creates and frees a small object per transaction.
#
#   tools/get_mimalloc.sh        -> build/mimalloc/src
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
REV=${MIMALLOC_REV:-v2.1.7}
SRC=$OCV/build/mimalloc/src
if [ ! -d "$SRC/.git" ]; then
    git clone --quiet -c advice.detachedHead=false --depth 1 --branch "$REV" https://github.com/microsoft/mimalloc "$SRC"
fi
echo "mimalloc $REV at $SRC"
