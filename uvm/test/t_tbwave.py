#!/usr/bin/env python3
"""t_tbwave.py - the waveform wrapper (tbwave.py) on a small top: transfers are counted as a monitor
sees them (valid, and ready when there is one), the dump starts N records before the named one and
ends M clocks after it.  t_tbwave.py <verilator> <work dir>"""
import os, re, subprocess, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from tbwave import wrapper

V, W = sys.argv[1], sys.argv[2]
os.makedirs(W, exist_ok=True)
# 'a': valid every 3rd clock, ready every 2nd -> a transfer every 6th clock;  'b': valid every 5th
top = """
module d (input logic clk, output logic a_valid, input logic a_ready, output logic b_valid);
    int n = 0;
    always @(posedge clk) n <= n + 1;
    assign a_valid = (n % 3) == 0;
    assign b_valid = (n % 5) == 0;
endmodule
module tb_top;
    logic clk = 0, rdy;
    int k = 0;
    always #5 clk = ~clk;
    always @(posedge clk) k <= k + 1;
    assign rdy = (k % 2) == 0;
    d dut (.clk(clk), .a_valid(), .a_ready(rdy), .b_valid());
    initial #100000 begin $display("NO END"); $finish; end
endmodule
"""
desc = {"_top": "tb_top", "_dut_instance": "dut", "clock": "clk",
        "channels": [{"name": "a", "valid": "a_valid", "ready": "a_ready"}, {"name": "b", "valid": "b_valid"}]}
open(f"{W}/top.sv", "w").write(top)
open(f"{W}/wave.sv", "w").write(wrapper(desc))
r = subprocess.run([V, "--binary", "--timing", "--trace", "-Wno-fatal", "-Wno-lint", "-Wno-style",
                    f"{W}/top.sv", f"{W}/wave.sv", "--top-module", "tb_top_wave", "--Mdir", f"{W}/obj"],
                   capture_output=True, text=True)
if r.returncode:
    print(r.stdout[-2000:], r.stderr[-2000:]); sys.exit(1)

fails = 0
def run(args, expect):
    global fails
    out = subprocess.run([f"{W}/obj/Vtb_top_wave"] + args, capture_output=True, text=True, cwd=W).stdout
    got = {k: int(v) for k, v in re.findall(r"OCV wave: (?:\S+ from|record \d+ of '\w+' at|\S+ written, to) (\d+)", out) and
           [("from", re.search(r"from (\d+)", out).group(1)), ("at", re.search(r" at (\d+)", out).group(1)),
            ("to", re.search(r"to (\d+)", out).group(1))]}
    ok = got == expect and os.path.getsize(f"{W}/ocv_wave.vcd") > 1000
    print(("ok  " if ok else "FAIL"), args, got)
    fails += not ok

# 'a': transfers at clocks 0, 6, 12, ... (posedge k: clock k at time 10k+5); record 10 = clock 54
run(["+OCV_WAVE=a:10", "+OCV_WAVE_BEFORE=3", "+OCV_WAVE_AFTER=4"], {"from": 10 * 36 + 5, "at": 10 * 54 + 5, "to": 10 * 58 + 5})
# 'b': every 5th clock (no ready); record 7 = clock 30
run(["+OCV_WAVE=b:7", "+OCV_WAVE_BEFORE=2", "+OCV_WAVE_AFTER=10"], {"from": 10 * 20 + 5, "at": 10 * 30 + 5, "to": 10 * 40 + 5})
# two named: the first to get close starts it (b:7 before a:10), each its own record mark
run(["+OCV_WAVE=a:10,b:7", "+OCV_WAVE_BEFORE=2", "+OCV_WAVE_AFTER=10"], {"from": 10 * 20 + 5, "at": 10 * 30 + 5, "to": 10 * 40 + 5})
print(f"tbwave tests: {3 - fails}/3 passed")
sys.exit(1 if fails else 0)
