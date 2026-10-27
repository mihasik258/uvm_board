#!/bin/sh
# use.sh <name> - the FPGA image <name> boots next (then: reboot): otbn, otbn_fault22, cva6_64, cva6_64_fault
F=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$F/BOOT_$1.BIN" ] || { echo "use.sh: no BOOT_$1.BIN"; ls "$F" | grep BOOT_; exit 1; }
cp "$F/BOOT_$1.BIN" "$F/BOOT.BIN" && echo "$1" > "$F/ocv/booted" && sync && echo "use.sh: $1 boots next - reboot"
