#!/usr/bin/env python3
"""cpu_wrap.py - a processor core as an OCV DUT, from a binding: which core, how its ports connect, where
its work is seen. The core's RTL is used as it is; the wrapper (memory, program loader, run control, bus
adapters, the streams of what the core does) is the same for every core - only the names differ.

    cpu_wrap.py <core.bind> -o <out dir>

Out:
  <name>_dut.sv   the wrapper (FPGA and simulation): module <name>_dut
  <name>.json     OCV descriptor: channel `program` (the RAM image, one word per record) and one monitor
                  channel per stream (lossless, squashed)
  ocv_cpu_wrap.h  the core for the reference model (models/cpu/ocv_cpu_model.c): ISA and profile,
                  memory map, streams
  ocv_cpu_pc.h    for the PC reference (hw/cpu/pc/tb_pc.cpp): the streams read from the Verilator model
  wrap.env        for the scripts (bash): RTL_SIM, RTL_FPGA (arrays), RTL_DEFINES, MODEL_SRCS, MODEL_CFLAGS, BATCH
                  (--batch for the runner: the program channel's depth)
  report.txt      every core port and what it is connected to

The binding (one directive per line, '#' starts a comment, ${VAR}: environment, OCV, EXT, SCR1, BIND):

  name    <name>                      the DUT's name
  core    <module>                    the core's top module
  files   <list> [base=DIR] [exclude=TEXT] [VAR=VALUE ...]
                                      RTL files from a file list (one per line; ${VAR} replaced; +incdir+
                                      lines become include directories; -F/-f: a nested list); relative to
                                      base (default: the list's directory); lines containing TEXT left out
  rtl     <file> ...                  RTL files; rtl.sim / rtl.fpga: only for simulation / the FPGA
  incdir  <dir> ...    define <NAME[=V]> ...    param <NAME>=<value>
  clock   <port>                      the core's clock input
  reset   <port> [low|high]           reset inputs of the core (held while the program loads, after the end)
  tie     <port> = <expression>       an input of the core; the expression may use rst_n (the wrapper's
                                      reset) and core_rst_n; an input not named anywhere is tied to 0
  bus     obi|axi <A|B> <prefix> [ro] [dev]
                                      the core's memory port: core ports <prefix><signal>[_i|_o] (OBI: req
                                      gnt rvalid addr we be wdata rdata; AXI4: aw* w* b* ar* r*) to RAM port
                                      A or B through ocv_obi_mem / ocv_axi_mem; ro: never writes (fetch);
                                      dev: the device windows are reached through this bus
  device  <name> <base> <bytes>       a device window: the core's accesses there go to the processor -
                                      channel dev_req (device, word address, we, byte enables, data, the
                                      core's clock count; writes are posted) and, for a read, the answer on
                                      dev_resp (the core's clock is held until it is there)
  memory  <bytes> [at <base>] [uram]  a RAM region (power of two, e.g. 64K; from address 0 or <base>; uram:
                                      in UltraRAM, for large ones); several for a sparse map (e.g. code low,
                                      stack high); the wrapper clears them after reset, the program brings
                                      only its non-zero words; generated programs use the first (at 0)
  boot    <address>    exit <address> the reset address; reaching exit ends the program (with an issue stream:
                                      a jump there - running into it in order does not, it may lie inside other
                                      code; with a retire stream: any way, as SCR1's tests run into 0xF8)
  stop    <address> [retire]          also a write to this device-window address ends it (e.g. a test's exit
                                      register); after the end only loads in flight complete. With `exit
                                      none` it is the only end: generated programs then end by that write.
                                      retire: the end is the store's retirement (the store stream), not its
                                      bus write - a core with a write buffer (CVA6) runs on meanwhile; the
                                      write still reaches the bus (DRAIN waits for it, up to 255 clocks)
  model   <ISA string>                for the reference model, e.g. rv32imc_zicsr_zifencei:cv32e40p
  gen     <generator>                 programs and coverage on the processor: cv32 (models/cpu/gen: RV32IMC,
                                      machine mode) or scr1 (examples/scr1: RV32IM, no traps)
  region  <base> <bytes>              memory inside the core (e.g. a TCM): the model has it too
  observed <base> <mask>              loads from (addr & mask) == base read what the core read (retire stream)
  csr     <number> <value>            a CSR the core hardwires (for models that keep no CSR state)
  logic                               SV code for the wrapper, the indented lines below (@x: core_i.x, or
                                      the core's port x)
  stream  <channel> <kind> [load|nonload] [cycle]
                                      what the core does, the indented lines below: `valid = <expr>`, one
                                      `<field> = <expr>` per field; cycle: each record also carries the
                                      core's clock count (not compared). Kinds and their fields (widths fixed):
            retire  one record per retired instruction: pc pc_next insn rd rd_wdata trap (any subset; pc_next
                    needed); the record whose pc_next is the exit address ends the run
            issue   instructions in program order: pc insn c (c: compressed); traps other than ecall/ebreak
                    are not issued (ecall: only ecall - a core whose trace has no ebreak, as CVA6's RVFI;
                    raw: insn of a compressed one is its 16 bits, else the 32-bit form);
                    the issue of the exit address ends the run (32 more clocks, then stop)
            regw    register writes (rd != 0): rd data; load / nonload: only loads / all but loads
            store   stores as the bus carries them: addr (word) be data (enabled bytes; a store across a
                    word is two)
            interrupt  the core took an interrupt: cause (its number); the wrapper adds seq, the number of
                    instructions of the end stream (issue or retire) before it - the model takes it there
            csrr    CSR reads that write a register, in program order: data - the model takes from here
                    what the core sets (mip, counters) and checks the rest
            watch   a value of the core, one record each time it changes: value (up to 32 bits) - not
                    predicted by the model; for coverage and monitors (UVM)
          interrupt, csrr and watch are not squashed (the model reads them record by record); the rest are
  latency                             the memory answers with random delays (the bus adapters: grant 0..G,
                                      response 0..R clocks): channel cfg_lat (seed, G, R), given by the model
                                      before each program (--model-opt lat=G,R; the seed changes per program)
  Always: stream `proto` (kind error) - the bus adapters' protocol checks (OBI: a waiting request keeps
          its address and data; AXI: a valid stays until accepted, its payload unchanged): value = the buses
          that broke a rule; the model expects none.
  input   <port> [irq [latency N]] [= <value>]
                                      an input of the core driven from the processor on a schedule: channel
                                      in_<port>, records (until, value) - the value holds until the core's
                                      clock count reaches `until`, then the next record; while it is not
                                      there the core's clock is held (nothing depends on how fast the
                                      processor is). <value>: before the first record and after the end
                                      (default 0). irq: the
                                      port is the core's interrupt lines (the model's generator schedules them);
                                      latency N: the core may take one up to N clocks after its line was
                                      raised (default 4; CVA6 takes them at commit)
"""
import argparse, glob, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OCV = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(OCV, "uvm"))
from lockstep import Tree   # noqa: E402  (Verilator's elaborated tree: ports and widths)

VERILATOR = os.path.join(OCV, "build", "verilator", "install", "bin", "verilator")
KINDS = {
    "retire": {"pc": 32, "pc_next": 32, "insn": 32, "rd": 5, "rd_wdata": 32, "trap": 1},
    "issue": {"pc": 32, "insn": 32, "c": 1},
    "regw": {"rd": 5, "data": 32},
    "store": {"addr": 32, "be": 4, "data": 32},
    "interrupt": {"cause": 32, "seq": 64},
    "csrr": {"data": 32},
    "watch": {"value": 32},
    "error": {"value": 32},
}
EXACT = ("interrupt", "csrr", "watch", "error")  # kinds kept record by record (never squashed)
OBI = ["req", "gnt", "rvalid", "addr", "we", "be", "wdata", "rdata"]
AXI = ["awid", "awaddr", "awlen", "awsize", "awburst", "awvalid", "awready", "wdata", "wstrb", "wlast", "wvalid", "wready",
       "bid", "bresp", "bvalid", "bready", "arid", "araddr", "arlen", "arsize", "arburst", "arvalid", "arready", "rid",
       "rdata", "rresp", "rlast", "rvalid", "rready"]
GENS = {"cv32": ("models/cpu/gen", ["cv32_gen.c", "cv32_cov.c"], "CPU_GEN_CV32"),
        "scr1": ("examples/scr1", ["scr1_gen.c", "scr1_cov.c"], "CPU_GEN_SCR1")}


class BindError(Exception):
    pass


def num(s):
    s = s.strip()
    m = re.fullmatch(r"(\d+)([KM])", s, re.I)
    if m:
        return int(m.group(1)) << (10 if m.group(2).upper() == "K" else 20)
    return int(s, 0)


# ---------------------------------------------------------------- the binding
class Bind:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.vars = dict(os.environ)
        self.vars.update(OCV=OCV, EXT=os.path.join(OCV, "ext"), BIND=os.path.dirname(self.path))
        self.vars.setdefault("SCR1", os.path.join(OCV, "ext", "scr1"))    # (tools/get_cores.sh)
        self.vars.setdefault("CV32E40P", os.path.join(self.vars["EXT"], "cv32e40p"))
        self.vars.setdefault("CVA6", os.path.join(self.vars["EXT"], "cva6"))
        if "SCR1_SRC" in os.environ:                  # another copy of scr1/src
            self.vars["SCR1"] = os.path.dirname(os.path.abspath(os.environ["SCR1_SRC"]))
        self.name = self.core = None
        self.rtl, self.rtl_sim, self.rtl_fpga, self.incdirs, self.defines, self.params = [], [], [], [], [], {}
        self.clock, self.resets, self.ties, self.buses = None, [], {}, []
        self.memory, self.boot, self.exit, self.model, self.gen = 0x10000, 0x200, 0xF8, "rv32imc_zicsr_zifencei", "cv32"
        self.regions, self.observed, self.csrs, self.logic, self.streams = [], [], [], [], []
        self.devices = []
        self.mems = []                               # RAM regions: base, size, uram
        self.stop = None
        self.stop_retire = False
        self.irq_window = 4
        self.inputs = []                              # (port, role, initial value)
        self.latency = False
        self._parse()

    def sub(self, s):
        def rep(m):
            v = m.group(1)
            if v not in self.vars:
                raise BindError(f"{self.path}: ${{{v}}} is not set")
            return self.vars[v]
        return re.sub(r"\$\{(\w+)\}", rep, s)

    def _parse(self):
        lines = open(self.path).read().split("\n")
        block = None
        for no, raw in enumerate(lines, 1):
            where = f"{self.path}:{no}"
            line = re.sub(r"(^|\s)#.*$", "", raw).rstrip()
            if not line.strip():
                continue
            if raw[:1] in " \t" and block is not None:      # a line of a block
                if block[0] == "logic":
                    self.logic.append(line)
                else:
                    m = re.fullmatch(r"\s*(\w+)\s*=\s*(.+)", line)
                    if not m:
                        raise BindError(f"{where}: expected '<field> = <expression>'")
                    block[1]["exprs"][m.group(1)] = m.group(2).strip()
                continue
            block = None
            w = line.split()
            d, args = w[0], w[1:]
            rest = line[len(d):].strip()
            if d == "name": self.name = args[0]
            elif d == "core": self.core = args[0]
            elif d in ("rtl", "rtl.sim", "rtl.fpga"):
                files = []
                for a in args:
                    g = sorted(glob.glob(self.sub(a)))
                    if not g:
                        raise BindError(f"{where}: no file {self.sub(a)}")
                    files += g
                {"rtl": self.rtl, "rtl.sim": self.rtl_sim, "rtl.fpga": self.rtl_fpga}[d].extend(files)
            elif d == "files": self._files(args, where)
            elif d == "incdir": self.incdirs += [self.sub(a) for a in args]
            elif d == "define": self.defines += [self.sub(a) for a in args]
            elif d == "param":
                k, v = rest.split("=", 1)
                self.params[k.strip()] = v.strip()
            elif d == "clock": self.clock = args[0]
            elif d == "reset": self.resets.append((args[0], (args[1] if len(args) > 1 else "low").lower()))
            elif d == "tie":
                k, v = rest.split("=", 1)
                self.ties[k.strip()] = v.strip()
            elif d == "bus":
                if len(args) < 3 or args[0] not in ("obi", "axi") or args[1] not in ("A", "B"):
                    raise BindError(f"{where}: bus obi|axi A|B <prefix> [ro]")
                self.buses.append({"proto": args[0], "port": args[1], "prefix": args[2], "ro": "ro" in args[3:],
                                   "dev": "dev" in args[3:]})
            elif d == "latency": self.latency = True
            elif d == "input":
                if not args:
                    raise BindError(f"{where}: input <port> [irq] [= <value>]")
                init = rest.split("=", 1)[1].strip() if "=" in rest else "'0"
                head = rest.split("=")[0].split()
                if "latency" in head:              # irq latency N: the core takes an interrupt up to N clocks late
                    self.irq_window = num(head[head.index("latency") + 1])
                self.inputs.append((args[0], "irq" if "irq" in args[1:] and "irq" in rest.split("=")[0] else "", init))
            elif d == "device":
                if len(args) != 3:
                    raise BindError(f"{where}: device <name> <base> <bytes>")
                self.devices.append((args[0], num(args[1]), num(args[2])))
            elif d == "memory":
                m = {"size": num(args[0]), "base": 0, "uram": "uram" in args[1:]}
                rest_m = [a for a in args[1:] if a != "uram"]
                if len(rest_m) == 2 and rest_m[0] == "at":
                    m["base"] = num(rest_m[1])
                elif rest_m:
                    raise BindError(f"{where}: memory <bytes> [at <base>] [uram]")
                self.mems.append(m)
            elif d == "boot": self.boot = num(args[0])
            elif d == "exit": self.exit = None if args[0] == "none" else num(args[0])
            elif d == "stop":
                self.stop = num(args[0])
                self.stop_retire = "retire" in args[1:]
            elif d == "model": self.model = args[0]
            elif d == "gen":
                if args[0] not in GENS:
                    raise BindError(f"{where}: generator {args[0]}: one of {', '.join(GENS)}")
                self.gen = args[0]
            elif d == "region": self.regions.append((num(args[0]), num(args[1])))
            elif d == "observed": self.observed.append((num(args[0]), num(args[1])))
            elif d == "csr": self.csrs.append((num(args[0]), num(args[1])))
            elif d == "logic": block = ("logic", None)
            elif d == "stream":
                if len(args) < 2 or args[1] not in KINDS:
                    raise BindError(f"{where}: stream <channel> {'|'.join(KINDS)} [load|nonload]")
                opts = args[2:]
                flt = [o for o in opts if o in ("load", "nonload", "all")]
                iss = [o for o in opts if o in ("ecall", "raw")]
                bad = [o for o in opts if o not in ("load", "nonload", "all", "ecall", "raw", "cycle")]
                if bad:
                    raise BindError(f"{where}: stream option(s) {bad}: load, nonload, ecall, raw, cycle")
                if iss and args[1] != "issue":
                    raise BindError(f"{where}: {iss}: options of issue streams")
                if iss:
                    flt = ["|".join(iss)]
                s = {"name": args[0], "kind": args[1], "filter": flt[0] if flt else "all", "exprs": {},
                     "cycle": "cycle" in opts}
                self.streams.append(s)
                block = ("stream", s)
            else:
                raise BindError(f"{where}: unknown directive '{d}'")
        for k in ("name", "core", "clock"):
            if not getattr(self, k):
                raise BindError(f"{self.path}: no '{k}'")
        if not self.mems:
            self.mems = [{"size": 0x10000, "base": 0, "uram": False}]
        for m in self.mems:
            if m["size"] & (m["size"] - 1) or m["size"] < 1024:
                raise BindError(f"{self.path}: memory 0x{m['size']:x}: a power of two, at least 1K")
        self.memory, self.mem_base = self.mems[0]["size"], self.mems[0]["base"]   # the first: generated programs
        for s in self.streams:
            if s["kind"] == "watch":
                if "valid" in s["exprs"] or "value" not in s["exprs"]:
                    raise BindError(f"{self.path}: stream {s['name']} (watch): only `value = <expr>` (a record when it changes)")
                continue
            if "valid" not in s["exprs"]:
                raise BindError(f"{self.path}: stream {s['name']}: no 'valid'")
            bad = [f for f in s["exprs"] if f != "valid" and (f not in KINDS[s["kind"]] or
                                                              (s["kind"] == "interrupt" and f == "seq"))]
            if bad:
                raise BindError(f"{self.path}: stream {s['name']} ({s['kind']}): unknown field(s) {bad}; "
                                f"fields: {' '.join(KINDS[s['kind']])}")
        # the protocol checks of the bus adapters: a stream the model expects nothing on
        self.streams.append({"name": "proto", "kind": "error", "filter": "all", "cycle": True, "auto": True,
                             "exprs": {"valid": "|proto_err", "value": "32'(proto_err)"}})
        if self.exit is None and self.stop is None:
            raise BindError(f"{self.path}: `exit none` needs a `stop`")
        if self.devices and sum(b["dev"] for b in self.buses) != 1:
            raise BindError(f"{self.path}: devices: mark the one bus that reaches them with 'dev'")
        ends = [s for s in self.streams if s["kind"] == "retire" and "pc_next" in s["exprs"]] or \
               [s for s in self.streams if s["kind"] == "issue" and "pc" in s["exprs"]]
        if not ends:
            raise BindError(f"{self.path}: a retire stream with pc_next or an issue stream with pc is needed (the end)")
        self.end = ends[0]

    def _files(self, args, where):
        lst = self.sub(args[0])
        base, exclude, vars_ = os.path.dirname(lst), [], {}
        for a in args[1:]:
            k, v = a.split("=", 1)
            if k == "base": base = self.sub(v)
            elif k == "exclude": exclude.append(self.sub(v))
            else: vars_[k] = self.sub(v)
        self._read_list(lst, base, exclude, vars_, where)

    def _read_list(self, lst, base, exclude, vars_, where):
        if not os.path.exists(lst):
            raise BindError(f"{where}: no file list {lst}")
        for l in open(lst):
            l = re.sub(r"//.*|#.*", "", l).strip()
            if not l:
                continue
            for k, v in vars_.items():
                l = l.replace("${" + k + "}", v).replace("$" + k, v)
            if l.startswith("+incdir+"):
                self.incdirs.append(os.path.join(base, l[8:]))
                continue
            if l.startswith("-F ") or l.startswith("-f "):      # a nested list: -F relative to itself
                sub = os.path.normpath(os.path.join(base, l[3:].strip()))
                self._read_list(sub, os.path.dirname(sub) if l[1] == "F" else base, exclude, vars_, where)
                continue
            if l.startswith("+") or l.startswith("-"):
                continue
            if any(e in l for e in exclude):
                continue
            self.rtl.append(os.path.normpath(os.path.join(base, l)))


# ---------------------------------------------------------------- the core's ports
def core_ports(b, tmp):
    rtl = b.rtl + b.rtl_sim
    cmd = [VERILATOR, "--json-only", "-Wno-fatal", "-Wno-lint", "-Wno-style", "--top-module", b.core, "--Mdir", tmp]
    cmd += [f"+incdir+{i}" for i in b.incdirs] + [f"+define+{d}" for d in b.defines]
    cmd += [f"-G{k}={v}" for k, v in b.params.items()] + rtl
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise BindError("Verilator could not elaborate the core:\n" +
                        "\n".join(l for l in (r.stdout + r.stderr).splitlines() if "%Error" in l)[:3000])
    t = Tree(os.path.join(tmp, f"V{b.core}.tree.json"))
    mod = t.module_of(b.core)
    return [(p["name"], p["direction"], t.width(p["dtypep"])) for p in Tree._members(mod, ("VAR",))
            if p.get("varType") == "PORT"]


def find_port(ports, prefix, sig):
    for n in (prefix + sig, prefix + sig + "_i", prefix + sig + "_o"):
        if n in ports:
            return n
    return None


# ---------------------------------------------------------------- the wrapper
def generate(b, ports, out):
    P = {n: (d, w) for n, d, w in ports}
    b.width_of = {n: w for n, d, w in ports}
    # the program channel: a whole program's non-zero words in one batch (at most 32 Ki: its buffer is block RAM)
    words = sum(m["size"] // 4 for m in b.mems)
    b.prog_depth = min(1 << 15, 1 << (words - 1).bit_length())
    aw = max((m["size"] // 4).bit_length() - 1 for m in b.mems)   # the largest region (the clear's counter)
    expr_of = {}                       # core input -> expression
    used_out = set()
    report = []

    def at(e):                         # @x: a port of the core (an output: its wire; an input: what drives it)
        def one(m):                    # or a signal inside it
            n = m.group(1)
            if n not in P:
                return f"core_i.{n}"
            if P[n][0] == "OUTPUT":
                return f"c_{n}"
            return "(" + expr_of.get(n, "'0") + ")"
        return re.sub(r"@([A-Za-z_]\w*)", one, e)

    if b.clock not in P or P[b.clock][0] != "INPUT":
        raise BindError(f"clock {b.clock}: no such input of {b.core}")
    expr_of[b.clock] = "clk"
    for r, lvl in b.resets:
        if r not in P:
            raise BindError(f"reset {r}: no such port of {b.core}")
        expr_of[r] = "core_rst_n" if lvl == "low" else "~core_rst_n"
    for k, v in b.ties.items():
        if k not in P or P[k][0] != "INPUT":
            raise BindError(f"tie {k}: no such input of {b.core}")
        expr_of[k] = at(v)
    for port, role, init in b.inputs:
        if port not in P or P[port][0] != "INPUT":
            raise BindError(f"input {port}: no such input of {b.core}")
        if port in b.ties:
            raise BindError(f"input {port}: also tied")
        expr_of[port] = f"(state_q == RUN ? in_{port}_q : {init})"     # after the end: the value before

    L = [f"// GENERATED by gen/cpu_wrap.py from {os.path.basename(b.path)}: {b.core} as an OCV DUT - RAM",
         "// " + ", ".join(f"{m['size'] // 1024} KiB at 0x{m['base']:x}" for m in b.mems) +
         ", program loader, run control, the core's streams. The core's RTL as it is.",
         f"module {b.name}_dut (",
         "    input  logic clk,",
         "    input  logic rst_n,",
         "    input  logic prog_valid,",
         "    output logic prog_ready,",
         "    input  logic [29:0] prog_addr,      // word address (byte address / 4)",
         "    input  logic [31:0] prog_data,",
         "    input  logic prog_last,"]
    if b.devices:
        L += ["    output logic dev_req_valid,", "    output logic [7:0] dev_req_dev,", "    output logic [31:0] dev_req_addr,",
              "    output logic dev_req_we,", "    output logic [3:0] dev_req_be,", "    output logic [31:0] dev_req_wdata,",
              "    output logic [63:0] dev_req_cycle,", "    input  logic dev_resp_valid,", "    output logic dev_resp_ready,",
              "    input  logic [31:0] dev_resp_rdata,"]
    if b.latency:
        L += ["    input  logic cfg_lat_valid,", "    output logic cfg_lat_ready,", "    input  logic [31:0] cfg_lat_seed,",
              "    input  logic [7:0] cfg_lat_gnt,", "    input  logic [7:0] cfg_lat_rsp,"]
    for port, role, init in b.inputs:
        w = P[port][1]
        L += [f"    input  logic in_{port}_valid,", f"    output logic in_{port}_ready,",
              f"    input  logic [63:0] in_{port}_until,", f"    input  logic [{w - 1}:0] in_{port}_value,"]
    for s in b.streams:
        L.append(f"    output logic {s['name']}_valid,")
        if s["kind"] == "interrupt":
            L.append(f"    output logic [63:0] {s['name']}_seq,")
        for f in s["exprs"]:
            if f != "valid":
                L.append(f"    output logic [{KINDS[s['kind']][f] - 1}:0] {s['name']}_{f},")
        if s["cycle"]:
            L.append(f"    output logic [63:0] {s['name']}_cycle,")
    L[-1] = L[-1].rstrip(",")
    drain = 32 if b.end["kind"] == "issue" else 0
    if b.stop_retire:
        drain = 256                      # until the stop write is on the bus (stop_bus), at most this long
    L += [");",
          f"    localparam int unsigned AW = {aw};",
          f"    localparam logic [31:0] EXIT = 32'h{(b.exit if b.exit is not None else 0xFFFFFFFF):08x};",
          "",
          "    // run control: CLEAR (the RAM to zero) -> LOAD (the program's words come in, the core in reset) -> RUN",
          "    // -> DRAIN -> HALT",
          "    typedef enum logic [2:0] {CLEAR, LOAD, RUN, DRAIN, HALT} state_e;",
          "    state_e     state_q;",
          "    logic [7:0] drain_q;",
          "    logic       stop_bus;          // the stop address's write on the bus (with `stop ... retire`: ends DRAIN)",
          "    logic [AW:0]   clr_q;",
          "    logic       at_exit, core_rst_n;",
          "    assign prog_ready = state_q == LOAD;",
          "    assign core_rst_n = rst_n & (state_q == RUN || state_q == DRAIN);",
          "    always_ff @(posedge clk) begin",
          "        if (~rst_n) begin",
          "            state_q <= CLEAR;",
          "            drain_q <= '0;",
          "            clr_q   <= '0;",
          "        end else unique case (state_q)",
          "            CLEAR:   begin clr_q <= clr_q + 1'b1; if (clr_q == (AW+1)'((1 << AW) - 1)) state_q <= LOAD; end",
          "            LOAD:    if (prog_valid && prog_last) state_q <= RUN;",
          f"            RUN:     if (at_exit) state_q <= {'DRAIN' if drain else 'HALT'};",
          f"            DRAIN:   begin drain_q <= drain_q + 8'd1; if (drain_q == 8'd{max(min(drain, 256) - 1, 0)}{' || stop_bus' if b.stop_retire else ''}) state_q <= HALT; end",
          "            default: ;",
          "        endcase",
          "    end",
          "",
          "    // RAM regions: ports A and B for the core's memory ports (byte addresses), A also for the loader",
          "    logic          a_en, b_en, a_hit, b_hit;",
          "    logic [3:0]    a_we, b_we;",
          "    logic [31:0]   a_addr, b_addr, a_wdata, b_wdata, a_rdata, b_rdata;",
          f"    logic [{len(b.mems) - 1}:0] a_sel, b_sel, a_sel_q, b_sel_q, ld_sel;",
          f"    logic [31:0]   a_rd [{len(b.mems)}];",
          f"    logic [31:0]   b_rd [{len(b.mems)}];",
          "    logic [31:0]   ld_byte;",
          "    assign ld_byte = {prog_addr, 2'b00};",
          "    always_ff @(posedge clk) begin a_sel_q <= a_sel; b_sel_q <= b_sel; end   // the read's region, a clock later",
          "    always_comb begin",
          "        a_rdata = '0; b_rdata = '0;",
          f"        for (int r = 0; r < {len(b.mems)}; r++) begin",
          "            if (a_sel_q[r]) a_rdata = a_rd[r];",
          "            if (b_sel_q[r]) b_rdata = b_rd[r];",
          "        end",
          "    end",
          "    assign a_hit = |a_sel;",
          "    assign b_hit = |b_sel;"]
    for r, m in enumerate(b.mems):
        raw = (m["size"] // 4).bit_length() - 1
        base, size = f"32'h{m['base']:08x}", f"32'h{m['size']:08x}"
        L += [f"    // region {r}: {m['size'] // 1024} KiB at 0x{m['base']:x}" + (" (UltraRAM)" if m["uram"] else ""),
              f"    assign a_sel[{r}]  = a_addr - {base} < {size};",
              f"    assign b_sel[{r}]  = b_addr - {base} < {size};",
              f"    assign ld_sel[{r}] = ld_byte - {base} < {size};",
              f"    ocv_cpu_ram #(.AW({raw}), .URAM(1'b{1 if m['uram'] else 0})) i_ram{r} (",
              "        .clk, .load(state_q == LOAD || state_q == CLEAR),",
              f"        .ld_valid(state_q == CLEAR ? clr_q < (AW+1)'({m['size'] // 4}) : prog_valid && prog_ready && ld_sel[{r}]),",
              f"        .ld_addr(state_q == CLEAR ? {raw}'(clr_q) : {raw}'((ld_byte - {base}) >> 2)),",
              "        .ld_data(state_q == CLEAR ? 32'h0 : prog_data),",
              f"        .a_en(a_en && a_sel[{r}]), .a_we(a_we), .a_addr({raw}'((a_addr - {base}) >> 2)), .a_wdata, .a_rdata(a_rd[{r}]),",
              f"        .b_en(b_en && b_sel[{r}]), .b_we(b_we), .b_addr({raw}'((b_addr - {base}) >> 2)), .b_wdata, .b_rdata(b_rd[{r}]));"]
    L += [          "",
          "    // the core's clock count (the hub holds the core's clock while it waits: those clocks do not count)",
          "    logic [63:0] cycle_q;",
          "    always_ff @(posedge clk) if (!core_rst_n) cycle_q <= '0; else cycle_q <= cycle_q + 64'd1;",
          "",
          "    // device windows: requests to the processor, answers from it",
          "    logic        dq_valid, dq_we, dq_hit, dr_ready;",
          "    logic [3:0]  dq_be;",
          "    logic [31:0] dq_addr, dq_wdata;",
          "    logic [7:0]  dq_dev;"]
    if b.devices:
        L.append("    always_comb begin")
        L.append("        dq_hit = 1'b0; dq_dev = '0;")
        for i, (n, base, size) in enumerate(b.devices):
            L.append(f"        if (dq_addr - 32'h{base:08x} < 32'h{size:08x}) begin dq_hit = 1'b1; dq_dev = 8'd{i}; end   // {n}")
        L.append("    end")
        L.append("    assign dev_req_valid = core_rst_n && " + ("(state_q == RUN || state_q == DRAIN)" if b.stop_retire
                 else "state_q == RUN") + " && dq_valid;" + ("   // (stop ... retire: the writes still buffered come in DRAIN)"
                 if b.stop_retire else ""))
        L.append("    assign dev_req_dev   = dq_dev;")
        L.append("    assign dev_req_addr  = {dq_addr[31:2], 2'b00};")
        L.append("    assign dev_req_we    = dq_we;")
        L.append("    assign dev_req_be    = dq_be;")
        L.append("    assign dev_req_wdata = dq_wdata & {32{dq_we}}   // (a read's wdata is whatever the core leaves there)")
        L.append("                         & {{8{dq_be[3]}}, {8{dq_be[2]}}, {8{dq_be[1]}}, {8{dq_be[0]}}};")
        L.append("    assign dev_req_cycle = cycle_q;")
        L.append("    assign dev_resp_ready = dr_ready;")
    else:
        L.append("    assign dq_hit = 1'b0;")

    # memory latency (cfg_lat: before the program) and the buses' protocol checks
    L += ["    logic [31:0] lat_seed_q;", "    logic [7:0]  lat_gnt_q, lat_rsp_q;",
          f"    logic [{max(len(b.buses), 1) - 1}:0] proto_err;"]
    if b.latency:
        L += ["    assign cfg_lat_ready = rst_n && (state_q == CLEAR || state_q == LOAD);   // (not in reset: it clears them)",
              "    always_ff @(posedge clk)",
              "        if (~rst_n) begin lat_seed_q <= '0; lat_gnt_q <= '0; lat_rsp_q <= '0; end",
              "        else if (cfg_lat_valid && cfg_lat_ready) begin",
              "            lat_seed_q <= cfg_lat_seed; lat_gnt_q <= cfg_lat_gnt; lat_rsp_q <= cfg_lat_rsp;",
              "        end"]
    else:
        L += ["    assign lat_seed_q = '0; assign lat_gnt_q = '0; assign lat_rsp_q = '0;"]
    if not b.buses:
        L += ["    assign proto_err = '0;"]
    # inputs on a schedule: (until, value) records; the core's clock is held while the next one is missing
    for port, role, init in b.inputs:
        w = P[port][1]
        L += [f"    logic [{w - 1}:0] in_{port}_q;",
              f"    logic [63:0] in_{port}_until_q;",
              f"    assign in_{port}_ready = core_rst_n && (state_q == RUN || state_q == DRAIN) ? cycle_q >= in_{port}_until_q",
              f"                           : state_q == HALT && in_{port}_valid;   // after the end: the rest is dropped",
              "    always_ff @(posedge clk)",
              f"        if (!core_rst_n) begin in_{port}_q <= {init}; in_{port}_until_q <= '0; end",
              f"        else if (in_{port}_valid && in_{port}_ready) begin in_{port}_q <= in_{port}_value; in_{port}_until_q <= in_{port}_until; end"]
    # core outputs as wires
    for n, d, w in ports:
        if d == "OUTPUT":
            L.append(f"    logic [{w - 1}:0] c_{n};")
    # buses
    ports_used = set()
    taken = set()
    for bus in b.buses:
        x = bus["port"].lower()
        if x in taken:
            raise BindError(f"RAM port {bus['port']} has two buses")
        taken.add(x)
        sigs = OBI if bus["proto"] == "obi" else AXI
        m = {s: find_port(P, bus["prefix"], s) for s in sigs}
        need = ["req", "gnt", "rvalid", "addr", "rdata"] if bus["proto"] == "obi" else \
               ["araddr", "arvalid", "arready", "rdata", "rvalid", "rready"]
        miss = [s for s in need if not m[s]]
        if miss:
            raise BindError(f"bus {bus['proto']} '{bus['prefix']}': no port for {miss}")
        inst = f"i_{bus['proto']}_{x}"
        conns = []
        for s in sigs:
            pn = m[s]
            if pn is None:
                continue
            ports_used.add(pn)
            if P[pn][0] == "INPUT":                      # adapter output -> core input
                L.append(f"    logic [{P[pn][1] - 1}:0] {inst}_{s};")
                expr_of[pn] = f"{inst}_{s}"
                conns.append(f".{s}({inst}_{s})")
            else:
                conns.append(f".{s}(c_{pn})")
                used_out.add(pn)
        if bus["proto"] == "obi":
            for s, dflt in (("we", "1'b0"), ("be", "4'hF"), ("wdata", "32'h0")):
                if not m[s]:
                    conns.append(f".{s}({dflt})")
            mod, prm = "ocv_obi_mem", f"#(.SALT(32'h{0x9E37 * len(taken):08x}))"
        else:
            idw = P[m["arid"]][1] if m["arid"] else 4
            dw = P[m["rdata"]][1]
            if dw not in (32, 64):
                raise BindError(f"bus axi '{bus['prefix']}': data {dw} bits wide - 32 or 64")
            # AXI4's defaults for signals a master leaves out (A10.3): full-width beats, INCR bursts
            full = {32: "3'd2", 64: "3'd3"}[dw]
            for s, dflt in (("awsize", full), ("arsize", full), ("awburst", "2'b01"), ("arburst", "2'b01")):
                if not m[s]:
                    conns.append(f".{s}({dflt})")
            for s in ("awid", "awaddr", "awlen", "awvalid", "wdata", "wstrb", "wlast", "wvalid", "bready",
                      "arid", "arlen", "rready"):
                if not m[s]:
                    conns.append(f".{s}('0)")
            mod, prm = "ocv_axi_mem", (f"#(.WRITE_EN(1'b{0 if bus['ro'] else 1}), .IDW({idw}), .DW({dw}), "
                                       f".SALT(32'h{0x9E37 * len(taken):08x}))")
        conns += [f".ram_en({x}_en)", f".ram_we({x}_we)", f".ram_addr({x}_addr)", f".ram_wdata({x}_wdata)",
                  f".ram_rdata({x}_rdata)", f".ram_hit({x}_hit)"]
        conns += [".lat_seed(lat_seed_q)", ".lat_gnt(lat_gnt_q)", ".lat_rsp(lat_rsp_q)",
                  f".proto_err(proto_err[{len(taken) - 1}])"]
        if bus["dev"]:
            conns += [".dev(dq_hit)", ".dreq_valid(dq_valid)", ".dreq_addr(dq_addr)", ".dreq_we(dq_we)",
                      ".dreq_be(dq_be)", ".dreq_wdata(dq_wdata)", ".dresp_ready(dr_ready)",
                      ".dresp_valid(dev_resp_valid)", ".dresp_rdata(dev_resp_rdata)"]
        else:
            conns += [".dev(1'b0)", ".dreq_valid()", ".dreq_addr()", ".dreq_we()", ".dreq_be()", ".dreq_wdata()",
                      ".dresp_ready()", ".dresp_valid(1'b0)", ".dresp_rdata(32'h0)"]
        L.append(f"    {mod} {prm} {inst} (.clk, .rst_n(core_rst_n), {', '.join(conns)});")
    for x in "ab":
        if x not in taken:
            L.append(f"    assign {x}_en = 1'b0; assign {x}_we = '0; assign {x}_addr = '0; assign {x}_wdata = '0;")

    # the core
    tied0 = []
    conns = []
    for n, d, w in ports:
        if d == "INPUT":
            e = expr_of.get(n)
            if e is None:
                e = "'0"
                tied0.append(n)
            conns.append(f"        .{n}({e})")
        else:
            conns.append(f"        .{n}(c_{n})")
    prm = (" #(" + ", ".join(f".{k}({v})" for k, v in b.params.items()) + ")") if b.params else ""
    L.append(f"    {b.core}{prm} core_i (")
    L.append(",\n".join(conns))
    L.append("    );")

    if b.logic:
        L.append("")
        L.append("    // from the binding")
        L += ["    " + at(l.strip()) if not l.startswith("    ") else at(l) for l in b.logic]

    # streams (registered: the strobes come from deep paths)
    L.append("")
    L.append("    // the streams")
    end = b.end
    endf = "pc_next" if end["kind"] == "retire" else "pc"
    if end["kind"] == "issue":
        # the end is a jump to EXIT, not running into it (EXIT may lie inside other programs' code)
        L += ["    logic [31:0] prev_next_q;           // where the last issued instruction falls through to,",
              "    logic        prev_jump_q;           // and whether it is a jump (even to the next address)",
              "    always_ff @(posedge clk)",
              "        if (!core_rst_n) begin prev_next_q <= '1; prev_jump_q <= 1'b0; end",
              f"        else if ({at(end['exprs']['valid'])}) begin",
              f"            prev_next_q <= ({at(end['exprs']['pc'])}) + ({at(end['exprs']['c']) if 'c' in end['exprs'] else '0'} ? 32'd2 : 32'd4);",
              f"            prev_jump_q <= ({at(end['exprs']['insn'])}) ==? 32'b????????????????????????_1101111 ||"
              f" ({at(end['exprs']['insn'])}) ==? 32'b????????????????????????_1100111 ||"
              f" ({at(end['exprs']['insn'])}) ==? 32'b????????????????????????_1100011;",
              "        end"]
        ends = [] if b.exit is None else \
            [f"(({at(end['exprs']['valid'])}) && ({at(end['exprs'][endf])}) == EXIT && (prev_jump_q || prev_next_q != EXIT))"]
    else:
        ends = [] if b.exit is None else [f"(({at(end['exprs']['valid'])}) && ({at(end['exprs'][endf])}) == EXIT)"]
    L.append("    logic stop_now;")
    if b.stop is not None:
        if not b.devices:
            raise BindError(f"stop 0x{b.stop:x}: needs the device window that holds it")
        L.append(f"    assign stop_bus = dq_valid && dq_we && {{dq_addr[31:2], 2'b00}} == 32'h{b.stop & ~3:08x};")
        if b.stop_retire:
            st = next((x for x in b.streams if x["kind"] == "store"), None)
            if st is None or "addr" not in st["exprs"]:
                raise BindError(f"stop 0x{b.stop:x} retire: needs a store stream with addr")
            L += ["    logic [31:0] stop_st_addr;",
                  f"    assign stop_st_addr = 32'({at(st['exprs']['addr'])});",
                  f"    assign stop_now = state_q == RUN && ({at(st['exprs']['valid'])}) && "
                  f"stop_st_addr[31:2] == 30'h{b.stop >> 2:08x};   // the store that ends the program retires"]
        else:
            L.append("    assign stop_now = state_q == RUN && stop_bus;   // the write that ends the program")
        ends.append("stop_now")
    else:
        L.append("    assign stop_now = 1'b0;")
        L.append("    assign stop_bus = 1'b0;")
    L.append(f"    assign at_exit = state_q == RUN && ({' || '.join(ends)});")
    for s in b.streams:                     # watch: a record when the value changes (and the first one)
        if s["kind"] == "watch":
            n = s["name"]
            L += [f"    logic [31:0] {n}_last_q;",
                  f"    logic        {n}_any_q;",
                  "    always_ff @(posedge clk)",
                  f"        if (!core_rst_n) begin {n}_any_q <= 1'b0; {n}_last_q <= '0; end",
                  f"        else if ((state_q == RUN || state_q == DRAIN) && (!{n}_any_q || 32'({at(s['exprs']['value'])}) != {n}_last_q)) begin",
                  f"            {n}_any_q <= 1'b1; {n}_last_q <= 32'({at(s['exprs']['value'])});",
                  "        end"]
            s["exprs"]["valid"] = f"(!{n}_any_q || 32'({s['exprs']['value']}) != {n}_last_q)"
    if any(s["kind"] == "interrupt" for s in b.streams):
        L += ["    // instructions of the end stream so far (an interrupt is taken after this many)",
              "    logic [63:0] seq_q;",
              "    logic        seq_now;",
              f"    assign seq_now = core_rst_n && ({at(end['exprs']['valid'])});",
              "    always_ff @(posedge clk) if (!core_rst_n) seq_q <= '0; else seq_q <= seq_q + {63'd0, seq_now};"]
    L.append("    always_ff @(posedge clk) begin")
    for s in b.streams:
        # after the end (DRAIN) only loads in flight complete (later instructions are not the program's)
        when = "(state_q == RUN || state_q == DRAIN)" if (s["kind"] == "regw" and s["filter"] == "load") \
            else "state_q == RUN" if s is not end or b.stop_retire else "state_q == RUN && !stop_now"   # (issued with the end write: after it)
        L.append(f"        {s['name']}_valid <= core_rst_n && {when} && ({at(s['exprs']['valid'])});")
        for f, e in s["exprs"].items():
            if f != "valid":
                L.append(f"        {s['name']}_{f} <= {at(e)};")
        if s["cycle"]:
            L.append(f"        {s['name']}_cycle <= cycle_q;")
        if s["kind"] == "interrupt":
            L.append(f"        {s['name']}_seq <= seq_q + {{63'd0, seq_now}};")
    L.append("    end")
    L.append(f"endmodule : {b.name}_dut")
    open(os.path.join(out, f"{b.name}_dut.sv"), "w").write("\n".join(L) + "\n")

    # report
    report.append(f"{b.name}: {b.core}, RAM " + ", ".join(f"{m['size'] // 1024} KiB at 0x{m['base']:x}" for m in b.mems) +
                  f", boot 0x{b.boot:x}" + (f", exit 0x{b.exit:x}" if b.exit is not None else "") +
                  (f", stop 0x{b.stop:x}" if b.stop is not None else ""))
    for n, d, w in ports:
        how = "clock" if n == b.clock else ("reset" if n in dict(b.resets) else
              ("bus" if n in ports_used else ("tie " + b.ties[n] if n in b.ties else
               ("0 (not named in the binding)" if n in tied0 else ("output, unused" if d == "OUTPUT" else "?")))))
        report.append(f"  {d.lower():6} [{w:3}] {n:28} {how}")
    open(os.path.join(out, "report.txt"), "w").write("\n".join(report) + "\n")
    return tied0, aw


def chan_fields(s):
    """the field names of stream s's channel, in the order descriptor() gives them"""
    return ([f for f in s["exprs"] if f != "valid"] + (["seq"] if s["kind"] == "interrupt" else []) +
            (["cycle"] if s["cycle"] else []))


def descriptor(b, aw, out):
    chans = [{"name": "program", "kind": "source", "depth": b.prog_depth, "valid": "prog_valid", "ready": "prog_ready",
              "description": "the program's non-zero words (the RAM regions are cleared after reset), one per record "
                             "(word address, data); 'last' starts the core",
              "fields": [{"name": "addr", "port": "prog_addr", "width": 30},
                         {"name": "data", "port": "prog_data", "width": 32},
                         {"name": "last", "port": "prog_last", "width": 1}]}]
    for s in b.streams:
        chans.append({"name": s["name"], "kind": "monitor", "depth": 4096, "lossless": True,
                      "squash": s["kind"] not in EXACT,
                      "valid": f"{s['name']}_valid", "description": f"{s['kind']} stream of {b.core}",
                      "fields": [{"name": f, "port": f"{s['name']}_{f}",
                                  "width": 64 if f in ("seq", "cycle") else KINDS[s["kind"]][f],
                                  **({"compare": "ignore"} if f == "cycle" else {})}
                                 for f in chan_fields(s)]})
    if b.devices:
        chans.append({"name": "dev_req", "kind": "monitor", "depth": 1024, "lossless": True, "valid": "dev_req_valid",
                      "description": "the core's accesses to device windows (" +
                                     ", ".join(f"{n} 0x{a:x}+0x{z:x}" for n, a, z in b.devices) + "); writes are posted",
                      "fields": [{"name": "dev", "port": "dev_req_dev", "width": 8},
                                 {"name": "addr", "port": "dev_req_addr", "width": 32},
                                 {"name": "we", "port": "dev_req_we", "width": 1},
                                 {"name": "be", "port": "dev_req_be", "width": 4},
                                 {"name": "wdata", "port": "dev_req_wdata", "width": 32},
                                 {"name": "cycle", "port": "dev_req_cycle", "width": 64, "compare": "ignore"}]})
        chans.append({"name": "dev_resp", "kind": "source", "depth": 1024, "stream": True, "freeze_when_starved": True,
                      "valid": "dev_resp_valid", "ready": "dev_resp_ready",
                      "description": "answers to device reads (the core's clock is held until one is there)",
                      "fields": [{"name": "rdata", "port": "dev_resp_rdata", "width": 32}]})
    for port, role, init in b.inputs:
        chans.append({"name": f"in_{port}", "kind": "source", "depth": 1024, "freeze_when_starved": True,
                      "valid": f"in_{port}_valid", "ready": f"in_{port}_ready",
                      "description": f"{port} of the core on a schedule: the value holds until the core's clock count "
                                     "reaches `until` (the core's clock is held while the next record is missing)",
                      "fields": [{"name": "until", "port": f"in_{port}_until", "width": 64},
                                 {"name": "value", "port": f"in_{port}_value", "width": b.width_of[port]}]})
    if b.latency:
        chans.append({"name": "cfg_lat", "kind": "source", "depth": 16, "valid": "cfg_lat_valid", "ready": "cfg_lat_ready",
                      "description": "the memory's random delays for the next program: seed, grant 0..gnt, response 0..rsp",
                      "fields": [{"name": "seed", "port": "cfg_lat_seed", "width": 32},
                                 {"name": "gnt", "port": "cfg_lat_gnt", "width": 8},
                                 {"name": "rsp", "port": "cfg_lat_rsp", "width": 8}]})
    d = {"name": b.name, "module": f"{b.name}_dut",
         "description": f"{b.core} (cpu_wrap.py, {os.path.basename(b.path)}): the program is the stimulus; "
                        f"what the core does is compared with the reference model ({b.model}).",
         "clock": "clk", "reset": {"port": "rst_n", "active": "low"}, "channels": chans}
    json.dump(d, open(os.path.join(out, f"{b.name}.json"), "w"), indent=2)


def sv_int(e):
    """the value of a constant SV expression of the binding: '0, 1'b1, 32'h200, 12"""
    e = e.strip()
    if e in ("'0", "0"):
        return 0
    if e == "'1":
        return (1 << 64) - 1
    m = re.fullmatch(r"(\d+)?'([bodh])([0-9a-fA-F_xzXZ]+)", e)
    if m:
        return int(m.group(3).replace("_", ""), {"b": 2, "o": 8, "d": 10, "h": 16}[m.group(2)])
    try:
        return int(e, 0)
    except ValueError:
        raise BindError(f"input value '{e}': a constant (e.g. 32'h0)")


def header(b, out):
    K = {"retire": "CPU_S_RETIRE", "issue": "CPU_S_ISSUE", "regw": "CPU_S_REGW", "store": "CPU_S_STORE",
         "interrupt": "CPU_S_INTR", "csrr": "CPU_S_CSRR", "watch": "CPU_S_WATCH", "error": "CPU_S_ERROR"}
    F = {"all": "CPU_W_ALL", "load": "CPU_W_LOAD", "nonload": "CPU_W_NONLOAD", "ecall": "CPU_I_ECALL",
         "raw": "CPU_I_RAW", "ecall|raw": "CPU_I_ECALL | CPU_I_RAW", "raw|ecall": "CPU_I_ECALL | CPU_I_RAW"}
    H = [f"/* GENERATED by gen/cpu_wrap.py from {os.path.basename(b.path)}: {b.core} for the reference model */",
         "#ifndef OCV_CPU_WRAP_H", "#define OCV_CPU_WRAP_H",
         f'#include "{b.name}_ocv_meta.h"',
         f"#define CPU_DUT       {b.name}_dut",
         f'#define CPU_NAME      "{b.name}"',
         f'#define CPU_ISA       "{b.model}"',
         f"#define CPU_RAM_BYTES 0x{b.memory:x}u   /* the first region: generated programs */",
         f"#define CPU_RAM_BASE  0x{b.mem_base:x}u",
         "static const uint32_t cpu_rams[][2] = {" + "".join(f" {{ 0x{m['base']:x}u, 0x{m['size']:x}u }}," for m in b.mems) + " };",
         f"#define CPU_N_RAMS {len(b.mems)}",
         f"#define CPU_BOOT      0x{b.boot:x}u",
         f"#define CPU_EXIT      0x{(b.exit if b.exit is not None else 0xFFFFFFFF):x}u   /* (none: 0xffffffff) */",
         f"#define CPU_END_ISSUE {1 if b.end['kind'] == 'issue' and b.exit is not None else 0}   /* the instruction at CPU_EXIT is issued */",
         f"#define CPU_STOP      0x{(b.stop if b.stop is not None else 0xFFFFFFFF) & ~3:x}u   /* a write there ends the program (or none) */",
         f"#define CPU_HAS_STOP  {0 if b.stop is None else 1}",
         f"#define CPU_IRQ_WINDOW {b.irq_window}u   /* an interrupt's line was raised at most this many clocks before */",
         f"#define {GENS[b.gen][2]} 1",
         "static const cpu_region_t cpu_regions_extra[] = {" +
         "".join(f" {{ 0x{a:x}u, 0x{n:x}u, NULL }}," for a, n in b.regions) + " { 0, 0, NULL } };",
         f"#define CPU_N_REGIONS_EXTRA {len(b.regions)}",
         "static const uint32_t cpu_observed[][2] = {" +
         "".join(f" {{ 0x{a:x}u, 0x{m:x}u }}," for a, m in b.observed) + " { 0, 0 } };",
         f"#define CPU_N_OBSERVED {len(b.observed)}",
         "static const cpu_csr_t cpu_fixed_csrs[] = {" +
         "".join(f" {{ 0x{a:x}u, 0x{v:x}u }}," for a, v in b.csrs) + " { 0, 0 } };",
         f"#define CPU_N_FIXED_CSRS {len(b.csrs)}",
         "/* streams: channel (1 + index; 0 is the program), kind, which register writes */",
         "static const cpu_stream_t cpu_streams[] = {" +
         "".join(f" {{ {i + 1}, {K[s['kind']]}, {F[s['filter']]} }}," for i, s in enumerate(b.streams)) + " };",
         f"#define CPU_N_STREAMS {len(b.streams)}",
         "/* each stream's values (cpu_streams.h order) as indexes into its channel's fields (-1: not reported), and",
         " * the streams an instruction makes records on, one by one: the model's per-instruction work is then",
         " * compiled for this core's layout (constant field positions) */",
         "static const signed char cpu_stream_field[][6] = {" +
         "".join(" { " + ", ".join(str(chan_fields(st).index(f)) if f in chan_fields(st) else "-1"
                                   for f in list(KINDS[st["kind"]]) + [None] * (6 - len(KINDS[st["kind"]]))) + " },"
                 for st in b.streams) + " };",
         "#define CPU_FOR_STREAMS(X)" + "".join(f" X({i})" for i, st in enumerate(b.streams)
                                               if st["kind"] not in ("interrupt", "watch", "error")),
         "/* device windows: base, bytes; channels dev_req / dev_resp follow the streams */",
         "static const uint32_t cpu_devices[][2] = {" +
         "".join(f" {{ 0x{a:x}u, 0x{z:x}u }}," for n, a, z in b.devices) + " { 0, 0 } };",
         f"#define CPU_N_DEVICES {len(b.devices)}",
         f"#define CPU_CH_DEV_REQ  {1 + len(b.streams)}",
         f"#define CPU_CH_DEV_RESP {2 + len(b.streams)}",
         "/* inputs on a schedule: channel, width, interrupt lines (1) or not, value before the first record */",
         "static const struct { int channel, width, irq; uint64_t init; } cpu_inputs[] = {" +
         "".join(f" {{ {1 + len(b.streams) + (2 if b.devices else 0) + i}, {b.width_of[p]}, {1 if r == 'irq' else 0}, "
                 f"0x{sv_int(v):x}ull }}," for i, (p, r, v) in enumerate(b.inputs)) + " { 0, 0, 0, 0 } };",
         f"#define CPU_N_INPUTS {len(b.inputs)}",
         f"#define CPU_CH_LAT {1 + len(b.streams) + (2 if b.devices else 0) + len(b.inputs) if b.latency else -1}"
         "   /* cfg_lat, or -1 */",
         "#endif"]
    open(os.path.join(out, "ocv_cpu_wrap.h"), "w").write("\n".join(H) + "\n")


def pc_header(b, out):
    order = {"retire": ["pc", "pc_next", "insn", "rd", "rd_wdata", "trap"], "issue": ["pc", "insn", "c"],
             "regw": ["rd", "data"], "store": ["addr", "be", "data"], "interrupt": ["cause", "seq"],
             "csrr": ["data"], "watch": ["value"], "error": ["value"]}           # cpu_streams.h
    H = [f"/* GENERATED by gen/cpu_wrap.py from {os.path.basename(b.path)}: the streams of V{b.name}_dut */",
         "#ifndef OCV_CPU_PC_H", "#define OCV_CPU_PC_H",
         f'#include "V{b.name}_dut.h"',
         f"typedef V{b.name}_dut cpu_pc_top_t;",
         "/* kind of each stream (0 retire, 1 issue, 2 regw, 3 store, as CPU_S_*), fields it has (cpu_streams.h order) */",
         "static const int cpu_pc_kind[] = {" + ", ".join(str(list(KINDS).index(s["kind"])) for s in b.streams) + "};",
         "static const unsigned char cpu_pc_has[][6] = {" +
         "".join(" { " + ", ".join("1" if f in s["exprs"] or (f == "seq" and s["kind"] == "interrupt") else "0"
                                   for f in order[s["kind"]] + [""] * (6 - len(order[s["kind"]]))) + " },"
                 for s in b.streams) + " };",
         "/* stream s: 1 and its values if it has a record this clock */",
         "static inline int cpu_pc_get(const cpu_pc_top_t *d, int s, uint32_t v[6])",
         "{",
         "    switch (s) {"]
    for i, st in enumerate(b.streams):
        H.append(f"    case {i}:")
        H.append(f"        if (!d->{st['name']}_valid) return 0;")
        for j, f in enumerate(order[st["kind"]]):
            has = f in st["exprs"] or (f == "seq" and st["kind"] == "interrupt")
            H.append(f"        v[{j}] = {'d->' + st['name'] + '_' + f if has else '0'};")
        H.append("        return 1;")
    H += ["    default: return 0;", "    }", "}"]
    H += ["/* the core's clock count of stream s's record (streams with `cycle`; else 0) */",
          "static inline uint64_t cpu_pc_cycle(const cpu_pc_top_t *d, int s)", "{", "    (void)d;", "    switch (s) {"]
    for i, st in enumerate(b.streams):
        if st["cycle"]:
            H.append(f"    case {i}: return d->{st['name']}_cycle;")
    H += ["    default: return 0;", "    }", "}"]
    H.append(f"#define CPU_PC_LATENCY {1 if b.latency else 0}")
    if b.latency:
        H += ["static inline void cpu_pc_lat(cpu_pc_top_t *d, int valid, uint32_t seed, uint32_t g, uint32_t r)",
              "{ d->cfg_lat_valid = valid; d->cfg_lat_seed = seed; d->cfg_lat_gnt = g; d->cfg_lat_rsp = r; }",
              "static inline int cpu_pc_lat_ready(const cpu_pc_top_t *d) { return d->cfg_lat_ready; }"]
    H.append(f"#define CPU_PC_DEVICES {len(b.devices)}")
    H.append(f"#define CPU_PC_INPUTS {len(b.inputs)}")
    H += ["/* input i on a schedule: wants a record / give one */",
          "static inline int cpu_pc_in_ready(const cpu_pc_top_t *d, int i)", "{", "    switch (i) {"]
    for i, (p, r, v) in enumerate(b.inputs):
        H.append(f"    case {i}: return d->in_{p}_ready;")
    H += ["    default: return 0;", "    }", "}",
          "static inline void cpu_pc_in_set(cpu_pc_top_t *d, int i, int valid, uint64_t until, uint64_t value)", "{",
          "    (void)d; (void)valid; (void)until; (void)value;", "    switch (i) {"]
    for i, (p, r, v) in enumerate(b.inputs):
        H.append(f"    case {i}: d->in_{p}_valid = valid; d->in_{p}_until = until; d->in_{p}_value = value; break;")
    H += ["    default: break;", "    }", "}"]
    if b.devices:
        H += ["/* a device request this clock: dev addr we be wdata */",
              "static inline int cpu_pc_dev_req(const cpu_pc_top_t *d, uint32_t v[5])",
              "{",
              "    if (!d->dev_req_valid) return 0;",
              "    v[0] = d->dev_req_dev; v[1] = d->dev_req_addr; v[2] = d->dev_req_we; v[3] = d->dev_req_be; v[4] = d->dev_req_wdata;",
              "    return 1;",
              "}",
              "static inline int  cpu_pc_dev_resp_ready(const cpu_pc_top_t *d) { return d->dev_resp_ready; }",
              "static inline void cpu_pc_dev_resp(cpu_pc_top_t *d, int valid, uint32_t rdata) { d->dev_resp_valid = valid; d->dev_resp_rdata = rdata; }"]
    H.append("#endif")
    open(os.path.join(out, "ocv_cpu_pc.h"), "w").write("\n".join(H) + "\n")


def env(b, out):
    gdir, gfiles, _ = GENS[b.gen]
    lib = [os.path.join(OCV, "hw", "cpu", f) for f in ("ocv_cpu_ram.sv", "ocv_obi_mem.sv", "ocv_axi_mem.sv")]
    dut = os.path.join(out, f"{b.name}_dut.sv")
    q = lambda xs: " ".join(f'"{x}"' for x in xs)
    E = [f"# GENERATED by gen/cpu_wrap.py from {b.path}",
         f"NAME={b.name}",
         f"BATCH={b.prog_depth}",
         f"DESC=\"{os.path.join(out, b.name + '.json')}\"",
         f"RTL_SIM=({q(b.rtl + b.rtl_sim + lib + [dut])})",
         f"RTL_FPGA=({q(b.rtl + b.rtl_fpga + lib + [dut])})",
         "RTL_DEFINES=\"" + " ".join([f"-I{i}" for i in b.incdirs] + [f"-D{d}" for d in b.defines]) + "\"",
         "MODEL_SRCS=\"" + " ".join([os.path.join(OCV, "models", "cpu", "iss", "rv32_iss.c"),
                                     os.path.join(OCV, "models", "cpu", "cpu_model.c"),
                                     os.path.join(OCV, "models", "cpu", "ocv_cov_filter.c")] +
                                    [os.path.join(OCV, gdir, f) for f in gfiles]) + "\"",
         "MODEL_CFLAGS=\"" + " ".join([f"-I{out}", f"-I{os.path.join(OCV, 'models', 'cpu')}",
                                       f"-I{os.path.join(OCV, 'models', 'cpu', 'iss')}",
                                       f"-I{os.path.join(OCV, gdir)}"]) + "\""]
    open(os.path.join(out, "wrap.env"), "w").write("\n".join(E) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("bind")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    try:
        b = Bind(a.bind)
        os.makedirs(a.out, exist_ok=True)
        out = os.path.abspath(a.out)
        with tempfile.TemporaryDirectory() as tmp:
            ports = core_ports(b, tmp)
        tied0, aw = generate(b, ports, out)
        descriptor(b, aw, out)
        header(b, out)
        pc_header(b, out)
        env(b, out)
    except BindError as e:
        sys.exit(f"cpu_wrap: {e}")
    print(f"cpu_wrap: {b.name}: {b.core}, {len(ports)} ports, {len(b.buses)} bus(es), {len(b.streams)} stream(s)"
          + (f"; tied to 0 (not in the binding): {' '.join(tied0)}" if tied0 else ""))


if __name__ == "__main__":
    main()
