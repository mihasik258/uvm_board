#!/usr/bin/env bash
# otbn_venv.sh - the Python environment of OpenTitan's tools that OCV uses for OTBN (FuseSoC for the RTL's file
# list, the OTBN assembler/linker, otbnsim): build/otbn_venv, the versions OpenTitan pins (python-requirements.txt)
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
V=$OCV/build/otbn_venv
[ -x "$V/bin/python" ] || python3 -m venv "$V"
"$V/bin/pip" install -q fusesoc==2.4.5 hjson==3.1.0 pyelftools==0.29 mako==1.3.10 pyyaml==6.0.3 \
    semantic-version==2.10.0 tabulate==0.10.0 pycryptodome==3.23.0
echo "otbn_venv.sh: $V"
