// tb_pc.cpp - the PC reference of a processor core under OCV (gen/cpu_wrap.py): the core's wrapper in
// Verilator, the same reference model (models/cpu/ocv_cpu_model.c, called through its plug-in interface),
// every record of every stream compared in the process - no OCV hub, no bus. What the board is measured
// against.
//
//   tb_pc [--batches N] [--max-cycles N (total, default 200M)] [--model-opt key=value ...]       (as the runner: gen=directed, program=..., cpu=...)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <vector>

#include "verilated.h"
#include "ocv_cpu_pc.h"

extern "C" {
#include "ocv.h"
#include "ocv_model.h"
}

namespace {

const char *const NAMES[8][6] = { { "pc", "pc_next", "insn", "rd", "rd_wdata", "trap" }, { "pc", "insn", "c" },
                                  { "rd", "data" }, { "addr", "be", "data" }, { "cause", "seq" }, { "data" }, { "value" }, { "value" } };   // cpu_streams.h
const int NS = sizeof cpu_pc_has / sizeof cpu_pc_has[0];
const int WORDS = 8;
#define CPU_CH_DEV_REQ_PC (NS + 1)                     // after the streams (cpu_wrap.py)
#define CPU_CH_LAT_PC (ocv_model_dut->n_channels - 1)    // cfg_lat: the last channel

struct rec_t { uint32_t w[WORDS]; };

cpu_pc_top_t *dut;
std::deque<rec_t> expect[NS], got[NS];         // expected (model) / produced (core), not yet compared
// the core's latest records of each stream (observed()): a window, not the whole batch - a program of hundreds of
// millions of instructions kept every record (gigabytes per run); the core is never more than 65536 records ahead
// of the model (emit), so the model's observed() asks well inside it
const size_t SEEN_KEEP = size_t(1) << 18;   // > AHEAD in observed()
std::deque<rec_t> seen[NS];
uint64_t seen_base[NS];                         // index (this batch) of seen[s].front()
static inline uint64_t seen_n(int s) { return seen_base[s] + seen[s].size(); }
std::vector<rec_t> dev_seen;                   // the core's device requests this batch
std::deque<uint32_t> dev_answers;              // answers react() gave, not yet taken by the core
std::deque<rec_t> dev_expect, dev_got;
struct sched_t { uint64_t until, value; };
std::deque<sched_t> in_q[CPU_PC_INPUTS + 1];   // input schedules (the model's stimulus), not yet taken
std::deque<rec_t> lat_q;                       // memory latency settings (cfg_lat), not yet taken
const ocv_field_t *fld[NS][6], *cyc[NS];      // fields per stream; its clock count (not compared)
uint64_t cycles, errors, compared, halted;
uint64_t max_cycles = 200000000;                // --max-cycles: a core that never ends fails instead
const uint64_t max_print = getenv("OCV_PC_ERRORS") ? strtoull(getenv("OCV_PC_ERRORS"), 0, 0) : 5;   // mismatches printed

ocv_model_io_t io;

bool was_ready;                                // the program word was taken at the last clock

void compare();

void tick()
{
    dut->clk = 0;
#if CPU_PC_DEVICES
    const bool give = !dev_answers.empty();                 // an answer waits: present it
    cpu_pc_dev_resp(dut, give, give ? dev_answers.front() : 0);
#endif
    bool in_give[CPU_PC_INPUTS + 1] = {};
    for (int i = 0; i < CPU_PC_INPUTS; i++) {
        in_give[i] = !in_q[i].empty();
        cpu_pc_in_set(dut, i, in_give[i], in_give[i] ? in_q[i].front().until : 0, in_give[i] ? in_q[i].front().value : 0);
    }
#if CPU_PC_LATENCY
    {
        const ocv_channel_t *c = &ocv_model_dut->channels[CPU_CH_LAT_PC];
        const bool lg = !lat_q.empty();
        cpu_pc_lat(dut, lg, lg ? (uint32_t)ocv_get(c, lat_q.front().w, "seed") : 0, lg ? (uint32_t)ocv_get(c, lat_q.front().w, "gnt") : 0,
                   lg ? (uint32_t)ocv_get(c, lat_q.front().w, "rsp") : 0);
    }
#endif
    dut->eval();
    was_ready = dut->prog_ready;
#if CPU_PC_LATENCY
    const bool lat_taken = !lat_q.empty() && cpu_pc_lat_ready(dut);
#endif
#if CPU_PC_DEVICES
    const bool taken = give && cpu_pc_dev_resp_ready(dut);
#endif
    bool in_taken[CPU_PC_INPUTS + 1] = {};
    for (int i = 0; i < CPU_PC_INPUTS; i++) in_taken[i] = in_give[i] && cpu_pc_in_ready(dut, i);
    Verilated::threadContextp()->time(cycles + 1);  // (the RTL's messages, e.g. a failed assertion, say the clock)
    dut->clk = 1; dut->eval();
    if (++cycles > max_cycles) {            // a core that does not end: what it did so far was compared
        compare();
        printf("tb_pc: FAIL - the core still runs after %llu clocks (--max-cycles); %llu mismatch(es) before\n",
               (unsigned long long)max_cycles, (unsigned long long)errors);
        std::fflush(stdout);
        std::exit(2);
    }
    for (int i = 0; i < CPU_PC_INPUTS; i++) if (in_taken[i]) in_q[i].pop_front();
#if CPU_PC_LATENCY
    if (lat_taken) lat_q.pop_front();
#endif
    uint32_t v[6];
    bool any = false;
#if CPU_PC_DEVICES
    if (taken) dev_answers.pop_front();
    uint32_t q[5];
    if (cpu_pc_dev_req(dut, q)) {                           // a device request: to the model's react()
        const ocv_channel_t *c = &ocv_model_dut->channels[CPU_CH_DEV_REQ_PC];
        rec_t r = {};
        static const char *const n[5] = { "dev", "addr", "we", "be", "wdata" };
        for (int j = 0; j < 5; j++) ocv_set(c, r.w, n[j], q[j]);
        dev_seen.push_back(r);
        dev_got.push_back(r);
        if (ocv_model.react) ocv_model.react(CPU_CH_DEV_REQ_PC, r.w, &io);
        any = true;
    }
#endif
    for (int s = 0; s < NS; s++)
        if (cpu_pc_get(dut, s, v)) {
            rec_t r = {};
            for (int j = 0; j < 6; j++)
                if (fld[s][j]) ocv_set_raw(r.w, fld[s][j], v[j]);
            if (cyc[s]) ocv_set_raw(r.w, cyc[s], cpu_pc_cycle(dut, s));
            got[s].push_back(r);
            seen[s].push_back(r);
            if (seen[s].size() > SEEN_KEEP) { seen[s].pop_front(); seen_base[s]++; }
            any = true;
        }
    halted = any ? 0 : halted + 1;
}

void compare()
{
    while (!dev_expect.empty() && !dev_got.empty()) {
        if (memcmp(&dev_expect.front(), &dev_got.front(), sizeof(rec_t))) {
            char a[256], b[256];
            const ocv_channel_t *c = &ocv_model_dut->channels[NS + 1];
            ocv_rec_format(c, dev_got.front().w, a, sizeof a);
            ocv_rec_format(c, dev_expect.front().w, b, sizeof b);
            if (errors++ < max_print) printf("tb_pc: MISMATCH device request: dut %s; model %s\n", a, b);
        }
        dev_expect.pop_front(); dev_got.pop_front();
        compared++;
    }
    for (int s = 0; s < NS; s++)
        while (!expect[s].empty() && !got[s].empty()) {
            if (cyc[s]) { ocv_set_raw(expect[s].front().w, cyc[s], 0); ocv_set_raw(got[s].front().w, cyc[s], 0); }
            if (memcmp(&expect[s].front(), &got[s].front(), sizeof(rec_t))) {
                const ocv_channel_t *c = &ocv_model_dut->channels[1 + s];
                char a[256], b[256];
                ocv_rec_format(c, got[s].front().w, a, sizeof a);
                ocv_rec_format(c, expect[s].front().w, b, sizeof b);
                if (errors++ < max_print) printf("tb_pc: MISMATCH channel '%s' record %llu (by clock %llu): dut %s; model %s\n",
                                         c->name, (unsigned long long)(seen_n(s) - got[s].size()),
                                         (unsigned long long)cycles, a, b);
            }
            expect[s].pop_front(); got[s].pop_front();
            compared++;
        }
}

// the core runs until it has given what the model expects (or it stops)
void catch_up(size_t backlog)
{
    for (;;) {
        compare();
        size_t n = 0;
        for (int s = 0; s < NS; s++) n += expect[s].size();
        if (n <= backlog || halted > 100000) return;
        tick();
    }
}

void emit(ocv_model_io_t *, int ch, const uint32_t *rec)
{
    rec_t r = {};
    memcpy(r.w, rec, ocv_model_dut->channels[ch].rec_words * 4u);
    if (ch == NS + 1) {                                      // a device request
        const ocv_field_t *cy = ocv_field(&ocv_model_dut->channels[ch], "cycle");
        if (cy) ocv_set_raw(r.w, cy, 0);                     // (not compared: the core's clock count)
        dev_expect.push_back(r);
        return;
    }
    expect[ch - 1].push_back(r);
    if (expect[ch - 1].size() > 65536) catch_up(1024);       // keep memory bounded on long runs
    if (expect[ch - 1].size() > (1u << 20)) {                // the core went quiet and the model runs on
        compare();
        printf("tb_pc: FAIL - the core gives nothing for %llu clocks while the model expects %zu more records; "
               "%llu mismatch(es) before\n", (unsigned long long)halted, expect[ch - 1].size(), (unsigned long long)errors);
        std::fflush(stdout);
        std::exit(2);
    }
}

void send(ocv_model_io_t *, int, const uint32_t *rec) { dev_answers.push_back(rec[0]); }

int observed(ocv_model_io_t *, int ch, uint32_t index, uint32_t *rec)
{
    if (ch == NS + 1) {                                      // a device request: the core runs until it made it
        while (dev_seen.size() <= index && halted < 100000) { tick(); compare(); }
        if (dev_seen.size() <= index) return 0;
        memcpy(rec, dev_seen[index].w, ocv_model_dut->channels[ch].rec_words * 4u);
        return 1;
    }
    const int s = ch - 1;
    // the core runs on until it made that record - but no further than AHEAD records past the model (a record that
    // never comes, the next interrupt of a program without any, would otherwise buffer the whole program): then
    // "not yet", and the model asks again later (ocv_cpu_model.c re-reads the next interrupt every 65536 instructions)
    const size_t AHEAD = size_t(1) << 17;
    auto ahead = [] { size_t m = 0; for (int k = 0; k < NS; k++) if (got[k].size() > m) m = got[k].size(); return m; };
    while (seen_n(s) <= index && halted < 5000 && ahead() < AHEAD) { tick(); compare(); }
    if (seen_n(s) <= index) return 0;
    if (index < seen_base[s]) {
        fprintf(stderr, "tb_pc: the model asked for record %u of '%s', no longer kept (window %zu)\n", index,
                ocv_model_dut->channels[ch].name, SEEN_KEEP);
        std::exit(3);
    }
    memcpy(rec, seen[s][index - seen_base[s]].w, ocv_model_dut->channels[ch].rec_words * 4u);
    return 1;
}

double now() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

}  // namespace

int main(int argc, char **argv)
{
    unsigned batches = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--batches") && i + 1 < argc) batches = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--model-opt") && i + 1 < argc) {
            char kv[512];
            snprintf(kv, sizeof kv, "%s", argv[++i]);
            char *eq = strchr(kv, '=');
            if (!eq || !ocv_model.configure || ocv_model.configure((*eq = 0, kv), eq + 1)) {
                fprintf(stderr, "tb_pc: model option '%s' not accepted\n", argv[i]);
                return 2;
            }
        } else if (strcmp(argv[i], "--reset-each-batch")) {
            fprintf(stderr, "tb_pc [--batches N] [--max-cycles N] [--model-opt key=value ...]\n");
            return 2;
        }
    }
    Verilated::commandArgs(1, argv);
    dut = new cpu_pc_top_t;
    for (int s = 0; s < NS; s++) {
        const ocv_channel_t *c = &ocv_model_dut->channels[1 + s];
        for (int j = 0; j < 6; j++)
            fld[s][j] = cpu_pc_has[s][j] ? ocv_field(c, NAMES[cpu_pc_kind[s]][j]) : nullptr;
        cyc[s] = ocv_field(c, "cycle");
    }
    io.emit = emit;
    io.observed = observed;
    io.send = send;
    const ocv_channel_t *pc = &ocv_model_dut->channels[0];
    uint64_t index = 0, rng = 1, in_index[CPU_PC_INPUTS + 1] = {};
    int cpu_inputs_pc[CPU_PC_INPUTS + 1] = {};
    for (int i = 0, ch = 0; ch < ocv_model_dut->n_channels; ch++)          // the input channels, in order
        if (!strncmp(ocv_model_dut->channels[ch].name, "in_", 3)) cpu_inputs_pc[i++] = ch;
    const double t0 = now();
    for (unsigned b = 0; b < batches; b++) {
        io.batch = b;
        ocv_model.reset();
        for (int s = 0; s < NS; s++) { expect[s].clear(); got[s].clear(); seen[s].clear(); seen_base[s] = 0; }
        dev_seen.clear(); dev_answers.clear(); dev_expect.clear(); dev_got.clear();
        for (int i = 0; i < CPU_PC_INPUTS; i++) in_q[i].clear();
        lat_q.clear();
#if CPU_PC_LATENCY
        {                                                    // the memory's delays: before the program
            rec_t r = {};
            if (ocv_model.stimulus(CPU_CH_LAT_PC, 0, r.w, &rng)) lat_q.push_back(r);
        }
#endif
        dut->rst_n = 0; dut->prog_valid = 0; tick(); tick(); dut->rst_n = 1;
        halted = 0;
        std::vector<rec_t> prog;
        for (;;) {                                           // the program: into the core, then the model
            rec_t r = {};
            if (!ocv_model.stimulus(0, index, r.w, &rng)) break;
            index++;
            prog.push_back(r);
            dut->prog_valid = 1;
            dut->prog_addr = (uint32_t)ocv_get(pc, r.w, "addr");
            dut->prog_data = (uint32_t)ocv_get(pc, r.w, "data");
            dut->prog_last = (uint32_t)ocv_get(pc, r.w, "last");
            do tick(); while (!was_ready);                     // (the wrapper clears the RAM first)
        }
        dut->prog_valid = 0;
        for (int i = 0; i < CPU_PC_INPUTS; i++) {            // the inputs' schedules for this program
            const int ch = cpu_inputs_pc[i];
            const ocv_channel_t *c = &ocv_model_dut->channels[ch];
            for (;;) {
                rec_t r = {};
                if (!ocv_model.stimulus(ch, in_index[i]++, r.w, &rng)) break;
                in_q[i].push_back({ (uint64_t)ocv_get(c, r.w, "until"), (uint64_t)ocv_get(c, r.w, "value") });
            }
        }
        halted = 0;                                          // (the load gave no records)
        for (const rec_t &r : prog) ocv_model.input(0, r.w, &io);   // the model runs the program
        catch_up(0);
        if (getenv("TBPC_DBG")) { for (int s2 = 0; s2 < NS; s2++) fprintf(stderr, "dbg s%d expect %zu got %zu seen %zu\n", s2, expect[s2].size(), got[s2].size(), seen[s2].size());
            fprintf(stderr, "dbg dev_seen %zu dev_got %zu dev_expect %zu answers %zu lat %zu in %zu\n", dev_seen.size(), dev_got.size(), dev_expect.size(), dev_answers.size(), lat_q.size(), in_q[0].size()); }
        while (halted < 1000) tick();                        // the core stops; anything more it gives is wrong
        compare();
        for (int s = 0; s < NS; s++)
            if (!expect[s].empty() || !got[s].empty()) {
                if (errors++ < max_print) printf("tb_pc: channel '%s': the core gave %zu records, the model expects %zu\n",
                                         ocv_model_dut->channels[1 + s].name, (size_t)seen_n(s),
                                         (size_t)(seen_n(s) - got[s].size() + expect[s].size()));
            }
        if (!dev_expect.empty() || !dev_got.empty())
            if (errors++ < max_print) printf("tb_pc: device requests: the core made %zu, the model expects %zu\n", dev_seen.size(),
                                     dev_seen.size() - dev_got.size() + dev_expect.size());
#ifdef CPU_STOP_ADDR
        {   /* what the program wrote to end itself: a self-checking program's verdict (core-v-verif's BSP: exit code) */
            const ocv_channel_t *c = &ocv_model_dut->channels[NS + 1];
            for (const rec_t &q : dev_seen)
                if (ocv_get(c, q.w, "we") && (uint32_t)ocv_get(c, q.w, "addr") == (CPU_STOP_ADDR & ~3u))
                    printf("tb_pc: batch %u: the program ended writing %llu to 0x%08x\n", b,
                           (unsigned long long)ocv_get(c, q.w, "wdata"), (unsigned)CPU_STOP_ADDR);
        }
#endif
    }
    const double t = now() - t0;
    printf("tb_pc: %s %s - %u batch(es), %llu records compared, %llu clocks, %.3f s\n", ocv_model_dut->name,
           errors ? "FAIL" : "PASS", batches, (unsigned long long)compared, (unsigned long long)cycles, t);
    delete dut;
    return errors ? 1 : 0;
}
