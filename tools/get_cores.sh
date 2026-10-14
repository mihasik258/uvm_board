#!/usr/bin/env bash
# get_cores.sh - the cores and testbenches the examples verify, at the commits this work was checked on,
# into ext/ (not part of this repository: they are other projects):
#   cv32e40p      OpenHW CV32E40P            (examples/cv32e40p)
#   core-v-verif  its UVM testbench           (examples/cv32e40p/uvm_fast, vlt.sh)
#   cva6          OpenHW CVA6 + hpdcache, cvfpu (examples/cva6)
#   xpack gcc     RISC-V toolchain for core-v-verif's programs (examples/cv32e40p/prog.sh)
#   embench-iot   real self-checking programs, the long tests (tools/embench.sh)
# SCR1 (examples/scr1) is the SCR1 with RVFI-lite of the pvo_scr1 project: SCR1=<its scr1 directory>, or a
# link ext/scr1 to it.
#
#   tools/get_cores.sh [--from <dir>]     --from: copy from an existing ext/ (hard links) instead of cloning
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXT=$ROOT/ext
FROM=
[ "${1:-}" = --from ] && FROM=$(realpath "$2")
mkdir -p "$EXT"

get() {   # name url commit [submodules...]
    local n=$1 url=$2 c=$3; shift 3
    if [ -d "$EXT/$n/.git" ] || [ -d "$EXT/$n" ]; then echo "get_cores: $n: present"; return; fi
    if [ -n "$FROM" ] && [ -d "$FROM/$n" ]; then
        cp -al "$FROM/$n" "$EXT/$n"; echo "get_cores: $n: from $FROM"
    else
        git clone -q "$url" "$EXT/$n"
        git -C "$EXT/$n" checkout -q "$c"
        [ $# -gt 0 ] && git -C "$EXT/$n" submodule update -q --init --recursive --depth 1 "$@"
        echo "get_cores: $n: $c"
    fi
    [ "$(git -C "$EXT/$n" rev-parse HEAD)" = "$c" ] || echo "get_cores: WARNING: $n is not at $c"
}

get cv32e40p     https://github.com/openhwgroup/cv32e40p.git     fcd59685681bc2b58e5805497b0c59df14eda810
get core-v-verif https://github.com/openhwgroup/core-v-verif.git 083728bd8d548fd188e0ef43e0c1b038bce24002
get cva6         https://github.com/openhwgroup/cva6.git         81245a47fad8fe1a5d562d953ef2662e099def76 \
    core/cache_subsystem/hpdcache core/cvfpu
get embench-iot  https://github.com/embench/embench-iot.git     09c2ed8c3b7008c95d08b038de4a3f6dc103ed70

X=xpack-riscv-none-elf-gcc-15.2.0-1
if [ ! -d "$EXT/$X" ]; then
    if [ -n "$FROM" ] && [ -d "$FROM/$X" ]; then cp -al "$FROM/$X" "$EXT/$X"
    else
        curl -sSL "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/$X-linux-x64.tar.gz" \
            | tar -xz -C "$EXT"
    fi
    echo "get_cores: $X"
fi
[ -e "$EXT/scr1" ] || echo "get_cores: SCR1: set SCR1=<pvo_scr1/scr1> or link ext/scr1 to it (examples/scr1)"
