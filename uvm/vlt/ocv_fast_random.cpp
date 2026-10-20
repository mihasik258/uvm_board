// ocv_fast_random.cpp - OCV's in-process constraint solver for Verilator's randomize().
//
// Verilator solves every constrained randomize() with an external SMT solver (z3, cvc5) over a
// pipe: several solver queries per call, ~17 ms on a PC - far more than everything else a UVM
// testbench does per transaction, and worse on the board's ARM. Most testbench constraints are
// simple: ranges, inside, dist, equalities, relations between a few fields. This solver handles
// them in the program itself and leaves the rest to the SMT solver, so the result is the same
// either way (IEEE 1800: a solution chosen uniformly among all solutions):
//
//  1. every constraint (SMT-LIB text, as Verilator builds it) is compiled once to an expression
//     tree (cached by its text);
//  2. a constraint on one variable built from comparisons with constants and and/or/not becomes
//     that variable's set of allowed values (a union of intervals); the sets are intersected;
//  3. each variable is drawn uniformly from its set; constraints over several variables (or of
//     a form step 2 does not reduce) are checked on the drawn values, and a draw that fails is
//     redrawn (rejection sampling - still uniform over the solutions);
//  4. if that keeps failing (tightly related variables), the variables are drawn one after the
//     other, each from the set the constraints allow given the ones already drawn (near-uniform,
//     as Verilator's own sampler);
//  5. anything else - arrays, randc, unique, solve-before, randomize(null), soft constraints that
//     cannot all hold (they are first tried as hard ones),
//     operators this file does not know, no solution found in OCV_FAST_RANDOM_TRIES rounds -
//     returns false and Verilator asks the SMT solver as before.
//
// Linked into the testbench (Verilator compiles it with the testbench's flags); the hook is
// tools/verilator/ocv_fast_random.patch. OCV_FAST_RANDOM=0 turns it off (for comparisons).
#include "verilated.h"
#include "verilated_random.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

typedef unsigned __int128 u128;

uint64_t mask(int w) { return w >= 64 ? ~0ULL : ((1ULL << w) - 1); }
int64_t sx(uint64_t v, int w) { return w >= 64 ? (int64_t)v : (int64_t)(v << (64 - w)) >> (64 - w); }

// ---------------------------------------------------------------- S-expressions
struct Sx {
    std::string atom;                  // empty for a list
    std::vector<Sx> kids;
    bool list() const { return atom.empty(); }
};

bool parseSx(const char*& p, Sx& out)
{
    while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
    if (!*p) return false;
    if (*p == '(') {
        p++;
        for (;;) {
            while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
            if (!*p) return false;
            if (*p == ')') { p++; break; }
            out.kids.emplace_back();
            if (!parseSx(p, out.kids.back())) return false;
        }
        return true;
    }
    if (*p == ')') return false;
    const char* s = p;
    while (*p && *p != ' ' && *p != '(' && *p != ')' && *p != '\n' && *p != '\t' && *p != '\r') p++;
    out.atom.assign(s, p - s);
    return true;
}

// ---------------------------------------------------------------- expressions
enum Op {
    CONST, VAR,                                          // bit-vector leaves (BOOL consts too)
    NOT, AND, OR, XOR, IMPLIES, EQ, DISTINCT, ITE,       // boolean (EQ/DISTINCT/ITE any type)
    ULT, ULE, UGT, UGE, SLT, SLE, SGT, SGE,
    BV2B, B2BV,                                          // __Vbool, __Vbv
    BNOT, BNEG, BAND, BOR, BXOR, ADD, SUB, MUL, UDIV, UREM, SDIV, SREM, SHL, LSHR, ASHR,
    CONCAT, EXTRACT, ZEXT, SEXT
};

struct Expr {
    Op op;
    int w = 0;                         // bit-vector width; 0 = Bool
    uint64_t c = 0;                    // CONST value
    int var = -1;                      // VAR index
    int p1 = 0, p2 = 0;                // EXTRACT hi/lo, ZEXT/SEXT amount
    std::vector<std::unique_ptr<Expr>> a;
};

struct Compiled {
    std::string text;                  // the SMT-LIB source (diagnostics)
    bool ok = false;
    std::unique_ptr<Expr> e;
    std::vector<int> vars;             // distinct variables it reads
};

struct Ctx {
    std::unordered_map<std::string, int> varIndex;   // SMT name -> index
    std::vector<int> width;
};

bool parseConst(const std::string& t, uint64_t& v, int& w)
{
    if (t.size() > 2 && t[0] == '#' && t[1] == 'b') {
        w = (int)t.size() - 2;
        if (w > 64) return false;
        v = 0;
        for (size_t i = 2; i < t.size(); i++) v = (v << 1) | (t[i] == '1');
        return true;
    }
    if (t.size() > 2 && t[0] == '#' && t[1] == 'x') {
        w = 4 * ((int)t.size() - 2);
        if (w > 64) return false;
        v = std::strtoull(t.c_str() + 2, nullptr, 16);
        return true;
    }
    return false;
}

std::unique_ptr<Expr> compile(const Sx& s, const Ctx& cx);

std::unique_ptr<Expr> mk(Op op, int w) { std::unique_ptr<Expr> e{new Expr}; e->op = op; e->w = w; return e; }

std::unique_ptr<Expr> compile(const Sx& s, const Ctx& cx)
{
    if (!s.list()) {
        uint64_t v; int w;
        if (s.atom == "true" || s.atom == "false") { auto e = mk(CONST, 0); e->c = s.atom == "true"; return e; }
        if (parseConst(s.atom, v, w)) { auto e = mk(CONST, w); e->c = v; return e; }
        auto it = cx.varIndex.find(s.atom);
        if (it == cx.varIndex.end()) return nullptr;
        auto e = mk(VAR, cx.width[it->second]);
        e->var = it->second;
        return e;
    }
    if (s.kids.empty()) return nullptr;
    const Sx& h = s.kids[0];
    // indexed operators: ((_ extract hi lo) x), ((_ zero_extend k) x), (_ bvN w)
    if (h.list()) {
        if (h.kids.size() < 2 || h.kids[0].atom != "_" || s.kids.size() != 2) return nullptr;
        auto x = compile(s.kids[1], cx);
        if (!x || x->w == 0) return nullptr;
        const std::string& f = h.kids[1].atom;
        if (f == "extract" && h.kids.size() == 4) {
            int hi = std::atoi(h.kids[2].atom.c_str()), lo = std::atoi(h.kids[3].atom.c_str());
            if (hi < lo || hi >= x->w) return nullptr;
            auto e = mk(EXTRACT, hi - lo + 1); e->p1 = hi; e->p2 = lo; e->a.push_back(std::move(x)); return e;
        }
        if ((f == "zero_extend" || f == "sign_extend") && h.kids.size() == 3) {
            int k = std::atoi(h.kids[2].atom.c_str());
            if (x->w + k > 64) return nullptr;
            auto e = mk(f == "zero_extend" ? ZEXT : SEXT, x->w + k); e->p1 = k; e->a.push_back(std::move(x)); return e;
        }
        return nullptr;
    }
    const std::string& f = h.atom;
    if (f == "_" && s.kids.size() == 3 && s.kids[1].atom.compare(0, 2, "bv") == 0) {
        int w = std::atoi(s.kids[2].atom.c_str());
        if (w < 1 || w > 64) return nullptr;
        auto e = mk(CONST, w); e->c = std::strtoull(s.kids[1].atom.c_str() + 2, nullptr, 10) & mask(w); return e;
    }
    std::vector<std::unique_ptr<Expr>> a;
    for (size_t i = 1; i < s.kids.size(); i++) {
        a.push_back(compile(s.kids[i], cx));
        if (!a.back()) return nullptr;
    }
    auto n = [&](size_t k) { return a.size() == k; };
    struct { const char* name; Op op; int kind; } T[] = {
        // kind: 0 bool->bool, 1 bv,bv->bool (same width), 2 bv..->bv (same width), 3 unary bv
        {"not", NOT, 0}, {"and", AND, 0}, {"or", OR, 0}, {"xor", XOR, 0}, {"=>", IMPLIES, 0},
        {"bvult", ULT, 1}, {"bvule", ULE, 1}, {"bvugt", UGT, 1}, {"bvuge", UGE, 1},
        {"bvslt", SLT, 1}, {"bvsle", SLE, 1}, {"bvsgt", SGT, 1}, {"bvsge", SGE, 1},
        {"bvand", BAND, 2}, {"bvor", BOR, 2}, {"bvxor", BXOR, 2}, {"bvadd", ADD, 2}, {"bvsub", SUB, 2},
        {"bvmul", MUL, 2}, {"bvudiv", UDIV, 2}, {"bvurem", UREM, 2}, {"bvsdiv", SDIV, 2},
        {"bvsrem", SREM, 2}, {"bvshl", SHL, 2}, {"bvlshr", LSHR, 2}, {"bvashr", ASHR, 2},
        {"bvnot", BNOT, 3}, {"bvneg", BNEG, 3},
    };
    std::unique_ptr<Expr> e;
    for (const auto& t : T) {
        if (f != t.name) continue;
        if (t.kind == 0) {
            if (a.empty() || (t.op == NOT && !n(1)) || (t.op == IMPLIES && !n(2))) return nullptr;
            for (auto& x : a) if (x->w) return nullptr;
            e = mk(t.op, 0);
        } else if (t.kind == 1) {
            if (!n(2) || !a[0]->w || a[0]->w != a[1]->w) return nullptr;
            e = mk(t.op, 0);
        } else if (t.kind == 2) {
            if (a.size() < 2 || !a[0]->w) return nullptr;
            for (auto& x : a) if (x->w != a[0]->w) return nullptr;
            if (a.size() > 2 && t.op != BAND && t.op != BOR && t.op != BXOR && t.op != ADD && t.op != MUL)
                return nullptr;
            e = mk(t.op, a[0]->w);
        } else {
            if (!n(1) || !a[0]->w) return nullptr;
            e = mk(t.op, a[0]->w);
        }
        break;
    }
    if (!e) {
        if (f == "=" || f == "distinct") {
            if (a.size() < 2) return nullptr;
            for (auto& x : a) if (x->w != a[0]->w) return nullptr;
            e = mk(f == "=" ? EQ : DISTINCT, 0);
        } else if (f == "ite") {
            if (!n(3) || a[0]->w || a[1]->w != a[2]->w) return nullptr;
            e = mk(ITE, a[1]->w);
        } else if (f == "__Vbool") {
            if (!n(1) || a[0]->w != 1) return nullptr;
            e = mk(BV2B, 0);
        } else if (f == "__Vbv") {
            if (!n(1) || a[0]->w) return nullptr;
            e = mk(B2BV, 1);
        } else if (f == "concat") {
            int w = 0;
            for (auto& x : a) { if (!x->w) return nullptr; w += x->w; }
            if (a.size() < 2 || w > 64) return nullptr;
            e = mk(CONCAT, w);
        } else {
            return nullptr;
        }
    }
    e->a = std::move(a);
    return e;
}

void collectVars(const Expr* e, std::vector<int>& vs)
{
    if (e->op == VAR) {
        for (int v : vs) if (v == e->var) return;
        vs.push_back(e->var);
    }
    for (const auto& x : e->a) collectVars(x.get(), vs);
}

uint64_t eval(const Expr* e, const uint64_t* val)
{
    const int w = e->w;
    auto A = [&](int i) { return eval(e->a[i].get(), val); };
    auto aw = [&](int i) { return e->a[i]->w; };
    switch (e->op) {
    case CONST: return e->c;
    case VAR: return val[e->var];
    case NOT: return !A(0);
    case AND: for (size_t i = 0; i < e->a.size(); i++) if (!A((int)i)) return 0; return 1;
    case OR: for (size_t i = 0; i < e->a.size(); i++) if (A((int)i)) return 1; return 0;
    case XOR: { uint64_t r = 0; for (size_t i = 0; i < e->a.size(); i++) r ^= A((int)i); return r; }
    case IMPLIES: return !A(0) || A(1);
    case EQ: { uint64_t v0 = A(0); for (size_t i = 1; i < e->a.size(); i++) if (A((int)i) != v0) return 0; return 1; }
    case DISTINCT:
        for (size_t i = 0; i < e->a.size(); i++)
            for (size_t j = i + 1; j < e->a.size(); j++) if (A((int)i) == A((int)j)) return 0;
        return 1;
    case ITE: return A(0) ? A(1) : A(2);
    case ULT: return A(0) < A(1);
    case ULE: return A(0) <= A(1);
    case UGT: return A(0) > A(1);
    case UGE: return A(0) >= A(1);
    case SLT: return sx(A(0), aw(0)) < sx(A(1), aw(1));
    case SLE: return sx(A(0), aw(0)) <= sx(A(1), aw(1));
    case SGT: return sx(A(0), aw(0)) > sx(A(1), aw(1));
    case SGE: return sx(A(0), aw(0)) >= sx(A(1), aw(1));
    case BV2B: return A(0) & 1;
    case B2BV: return A(0) ? 1 : 0;
    case BNOT: return ~A(0) & mask(w);
    case BNEG: return (0 - A(0)) & mask(w);
    case BAND: { uint64_t r = A(0); for (size_t i = 1; i < e->a.size(); i++) r &= A((int)i); return r; }
    case BOR: { uint64_t r = A(0); for (size_t i = 1; i < e->a.size(); i++) r |= A((int)i); return r; }
    case BXOR: { uint64_t r = A(0); for (size_t i = 1; i < e->a.size(); i++) r ^= A((int)i); return r; }
    case ADD: { uint64_t r = A(0); for (size_t i = 1; i < e->a.size(); i++) r += A((int)i); return r & mask(w); }
    case MUL: { uint64_t r = A(0); for (size_t i = 1; i < e->a.size(); i++) r *= A((int)i); return r & mask(w); }
    case SUB: return (A(0) - A(1)) & mask(w);
    case UDIV: { uint64_t d = A(1); return d ? A(0) / d : mask(w); }           // SMT-LIB: x/0 = ~0
    case UREM: { uint64_t d = A(1), x = A(0); return d ? x % d : x; }         //          x%0 = x
    case SDIV: {
        int64_t x = sx(A(0), w), d = sx(A(1), w);
        if (!d) return x < 0 ? 1 : mask(w);
        if (w == 64 && x == INT64_MIN && d == -1) return (uint64_t)x;
        return (uint64_t)(x / d) & mask(w);
    }
    case SREM: {
        int64_t x = sx(A(0), w), d = sx(A(1), w);
        if (!d) return (uint64_t)x & mask(w);
        if (w == 64 && x == INT64_MIN && d == -1) return 0;
        return (uint64_t)(x % d) & mask(w);
    }
    case SHL: { uint64_t s = A(1); return s >= (uint64_t)w ? 0 : (A(0) << s) & mask(w); }
    case LSHR: { uint64_t s = A(1); return s >= (uint64_t)w ? 0 : A(0) >> s; }
    case ASHR: { uint64_t s = A(1); int64_t x = sx(A(0), w); return (uint64_t)(x >> (s >= (uint64_t)w ? w - 1 : s)) & mask(w); }
    case CONCAT: { uint64_t r = 0; for (size_t i = 0; i < e->a.size(); i++) r = (aw((int)i) >= 64 ? 0 : r << aw((int)i)) | A((int)i); return r & mask(w); }
    case EXTRACT: return (A(0) >> e->p2) & mask(w);
    case ZEXT: return A(0);
    case SEXT: return (uint64_t)sx(A(0), aw(0)) & mask(w);
    }
    return 0;
}

// ---------------------------------------------------------------- value sets
// Sorted, disjoint, inclusive intervals of a variable's (unsigned) value.
struct Set {
    std::vector<std::pair<uint64_t, uint64_t>> iv;
    static Set full(int w) { Set s; s.iv.push_back({0, mask(w)}); return s; }
    static Set range(uint64_t lo, uint64_t hi) { Set s; if (lo <= hi) s.iv.push_back({lo, hi}); return s; }
    bool empty() const { return iv.empty(); }
    u128 size() const { u128 n = 0; for (const auto& r : iv) n += (u128)(r.second - r.first) + 1; return n; }
};

Set setAnd(const Set& x, const Set& y)
{
    Set r;
    size_t i = 0, j = 0;
    while (i < x.iv.size() && j < y.iv.size()) {
        uint64_t lo = std::max(x.iv[i].first, y.iv[j].first), hi = std::min(x.iv[i].second, y.iv[j].second);
        if (lo <= hi) r.iv.push_back({lo, hi});
        if (x.iv[i].second < y.iv[j].second) i++; else j++;
    }
    return r;
}

Set setOr(const Set& x, const Set& y)
{
    std::vector<std::pair<uint64_t, uint64_t>> all(x.iv);
    all.insert(all.end(), y.iv.begin(), y.iv.end());
    std::sort(all.begin(), all.end());
    Set r;
    for (const auto& p : all) {
        if (!r.iv.empty() && (r.iv.back().second == ~0ULL || p.first <= r.iv.back().second + 1))
            r.iv.back().second = std::max(r.iv.back().second, p.second);
        else
            r.iv.push_back(p);
    }
    return r;
}

Set setNot(const Set& x, int w)
{
    Set r;
    uint64_t next = 0, top = mask(w);
    bool done = false;
    for (const auto& p : x.iv) {
        if (p.first > next) r.iv.push_back({next, p.first - 1});
        if (p.second >= top) { done = true; break; }
        next = p.second + 1;
    }
    if (!done) r.iv.push_back({next, top});
    return r;
}

// a signed interval [lo, hi] of the variable (width w) as its unsigned encodings
Set fromSigned(int64_t lo, int64_t hi, int w)
{
    const int64_t smin = w >= 64 ? INT64_MIN : -(int64_t)(1ULL << (w - 1));
    const int64_t smax = w >= 64 ? INT64_MAX : (int64_t)((1ULL << (w - 1)) - 1);
    lo = std::max(lo, smin);
    hi = std::min(hi, smax);
    if (lo > hi) return Set{};
    const uint64_t m = mask(w);
    if (lo >= 0) return Set::range((uint64_t)lo, (uint64_t)hi);
    if (hi < 0) return Set::range((uint64_t)lo & m, (uint64_t)hi & m);
    return setOr(Set::range(0, (uint64_t)hi), Set::range((uint64_t)lo & m, m));
}

// Variables whose value is known while a set is computed (rand_mode off, or already drawn):
// they count as constants. The variable the set is for is never known.
const uint64_t* g_val;
const char* g_known;

bool isConst(const Expr* e)
{
    if (e->op == VAR) return g_known && g_known[e->var];
    for (const auto& x : e->a) if (!isConst(x.get())) return false;
    return true;
}

// S moved by d (mod 2^w): {(v + d) mod 2^w : v in S}
Set setShift(const Set& x, uint64_t d, int w)
{
    const uint64_t m = mask(w);
    d &= m;
    Set r;
    for (const auto& p : x.iv) {
        const uint64_t lo = (p.first + d) & m, hi = (p.second + d) & m;
        if (lo <= hi) r = setOr(r, Set::range(lo, hi));
        else r = setOr(r, setOr(Set::range(lo, m), Set::range(0, hi)));   // wrapped around
    }
    return r;
}

// {(-v) mod 2^w : v in S}
Set setNeg(const Set& x, int w)
{
    const uint64_t m = mask(w);
    Set r;
    for (const auto& p : x.iv) {
        if (p.first == 0) {
            r = setOr(r, Set::range(0, 0));
            if (p.second) r = setOr(r, Set::range((0 - p.second) & m, m));
        } else {
            r = setOr(r, Set::range((0 - p.second) & m, (0 - p.first) & m));
        }
    }
    return r;
}

// The values of `var` for which the term t (built from var by extensions and by adding,
// subtracting, negating known values) lies in S (a set of t's own width).
bool preimage(const Expr* t, int var, const Set& S, Set& out)
{
    if (t->op == VAR) {
        if (t->var != var) return false;
        out = S;
        return true;
    }
    const int W = t->w;
    switch (t->op) {
    case ZEXT: {
        const int w0 = t->a[0]->w;
        return preimage(t->a[0].get(), var, setAnd(S, Set::range(0, mask(w0))), out);
    }
    case SEXT: {
        const int w0 = t->a[0]->w;
        if (w0 == W) return preimage(t->a[0].get(), var, S, out);
        // inner u < 2^(w0-1) appears as u; a negative inner u appears as u - 2^w0 (mod 2^W)
        const uint64_t half = 1ULL << (w0 - 1);
        const Set pos = setAnd(S, Set::range(0, half - 1));
        const Set neg = setShift(setAnd(S, Set::range((0 - half) & mask(W), mask(W))), 1ULL << w0, W);
        return preimage(t->a[0].get(), var, setAnd(setOr(pos, neg), Set::range(0, mask(w0))), out);
    }
    case ADD: case SUB: {
        if (t->a.size() != 2) return false;
        const bool k0 = isConst(t->a[0].get()), k1 = isConst(t->a[1].get());
        if (k0 == k1) return false;
        const uint64_t k = eval(t->a[k0 ? 0 : 1].get(), g_val);
        const Expr* x = t->a[k0 ? 1 : 0].get();
        if (t->op == ADD) return preimage(x, var, setShift(S, 0 - k, W), out);       // x + k in S
        if (k1) return preimage(x, var, setShift(S, k, W), out);                     // x - k in S
        return preimage(x, var, setNeg(setShift(S, 0 - k, W), W), out);              // k - x in S
    }
    case BNEG: return preimage(t->a[0].get(), var, setNeg(S, W), out);
    case BNOT: return preimage(t->a[0].get(), var, setNeg(setShift(S, 1, W), W), out);  // ~x = -x - 1
    default: return false;
    }
}

bool boolSet(const Expr* e, int var, int w, Set& out);

// the set where a 1-bit vector expression equals `want`
bool bitSet(const Expr* e, int var, int w, bool want, Set& out)
{
    if (isConst(e)) { out = (eval(e, g_val) & 1) == want ? Set::full(w) : Set{}; return true; }
    if (e->op == B2BV) {
        Set s;
        if (!boolSet(e->a[0].get(), var, w, s)) return false;
        out = want ? s : setNot(s, w);
        return true;
    }
    if (e->op == BNOT) return bitSet(e->a[0].get(), var, w, !want, out);
    if (e->op == BAND || e->op == BOR) {
        // want 1 of an AND: all 1; want 0 of an AND: any 0 (and the dual for OR)
        const bool all = (e->op == BAND) == want;
        for (size_t i = 0; i < e->a.size(); i++) {
            Set s;
            if (!bitSet(e->a[i].get(), var, w, want, s)) return false;
            out = i == 0 ? s : all ? setAnd(out, s) : setOr(out, s);
        }
        return true;
    }
    return false;
}

// comparison of a term of the variable with a known value
bool cmpSet(Op op, const Expr* x, const Expr* k, int var, int w, Set& out)
{
    if (!isConst(k)) {
        if (!isConst(x)) return false;
        std::swap(x, k);                             // known value on the left: mirror the operator
        switch (op) {
        case ULT: op = UGT; break; case ULE: op = UGE; break; case UGT: op = ULT; break; case UGE: op = ULE; break;
        case SLT: op = SGT; break; case SLE: op = SGE; break; case SGT: op = SLT; break; case SGE: op = SLE; break;
        default: break;
        }
    }
    const int W = x->w;
    const uint64_t kc = eval(k, g_val);
    Set S;                                           // the values of x (W bits) that satisfy it
    switch (op) {
    case EQ: S = Set::range(kc, kc); break;
    case DISTINCT: S = setNot(Set::range(kc, kc), W); break;
    case ULT: S = kc ? Set::range(0, kc - 1) : Set{}; break;
    case ULE: S = Set::range(0, kc); break;
    case UGT: S = kc < mask(W) ? Set::range(kc + 1, mask(W)) : Set{}; break;
    case UGE: S = Set::range(kc, mask(W)); break;
    case SLT: case SLE: case SGT: case SGE: {
        const int64_t c = sx(kc, W);
        const int64_t smin = W >= 64 ? INT64_MIN : -(int64_t)(1ULL << (W - 1));
        const int64_t smax = W >= 64 ? INT64_MAX : (int64_t)((1ULL << (W - 1)) - 1);
        int64_t lo = smin, hi = smax;
        if (op == SLT) { if (c == smin) { S = Set{}; break; } hi = c - 1; }
        if (op == SLE) hi = c;
        if (op == SGT) { if (c == smax) { S = Set{}; break; } lo = c + 1; }
        if (op == SGE) lo = c;
        S = fromSigned(lo, hi, W);
        break;
    }
    default: return false;
    }
    (void)w;
    return preimage(x, var, S, out);
}

// the set of the variable's values that make the boolean expression true; false = not reducible
bool boolSet(const Expr* e, int var, int w, Set& out)
{
    if (isConst(e)) { out = eval(e, g_val) ? Set::full(w) : Set{}; return true; }
    switch (e->op) {
    case NOT: { Set s; if (!boolSet(e->a[0].get(), var, w, s)) return false; out = setNot(s, w); return true; }
    case AND: case OR:
        for (size_t i = 0; i < e->a.size(); i++) {
            Set s;
            if (!boolSet(e->a[i].get(), var, w, s)) return false;
            out = i == 0 ? s : e->op == AND ? setAnd(out, s) : setOr(out, s);
        }
        return true;
    case IMPLIES: {
        Set p, q;
        if (!boolSet(e->a[0].get(), var, w, p) || !boolSet(e->a[1].get(), var, w, q)) return false;
        out = setOr(setNot(p, w), q);
        return true;
    }
    case BV2B: return bitSet(e->a[0].get(), var, w, true, out);
    case EQ: case DISTINCT:
        if (e->a.size() != 2) return false;
        if (e->a[0]->w == 1) {                       // (= #b1 X): X is a 1-bit condition
            const Expr* c = e->a[0]->op == CONST ? e->a[0].get() : e->a[1]->op == CONST ? e->a[1].get() : nullptr;
            const Expr* x = c == e->a[0].get() ? e->a[1].get() : e->a[0].get();
            if (c && !(x->op == VAR && x->var == var))
                return bitSet(x, var, w, (c->c & 1) == (e->op == EQ), out);
        }
        return cmpSet(e->op, e->a[0].get(), e->a[1].get(), var, w, out);
    case ULT: case ULE: case UGT: case UGE: case SLT: case SLE: case SGT: case SGE:
        return cmpSet(e->op, e->a[0].get(), e->a[1].get(), var, w, out);
    default: return false;
    }
}

uint64_t draw(const Set& s, VlRNG& rng)
{
    const u128 n = s.size();
    u128 r = n == ((u128)1 << 64) ? (u128)rng.rand64() : (u128)(rng.rand64() % (uint64_t)n);
    for (const auto& p : s.iv) {
        const u128 len = (u128)(p.second - p.first) + 1;
        if (r < len) return p.first + (uint64_t)r;
        r -= len;
    }
    return s.iv.back().second;
}

// ---------------------------------------------------------------- plans
// A randomize() call site builds the same variables and constraint texts every time: everything that
// does not depend on the drawn values (compiled constraints, each variable's set, the groups) is
// kept per call shape, so a repeated call only draws. Only for calls without frozen variables (their
// current values would enter the sets); a plan whose quick draw fails sends the call the full way.
struct Plan {
    std::vector<std::string> names, texts;     // the shape it was made for (checked on every hit)
    std::vector<int> widths;
    std::vector<Set> dom;
    struct Group { std::vector<int> mem; std::vector<const Compiled*> cons; };
    std::vector<Group> groups;
    std::vector<std::shared_ptr<Compiled>> keep;   // the compiled constraints stay alive
    bool quick = true;                         // independent draws work here (off after one failure)
};
std::unordered_map<uint64_t, std::unique_ptr<Plan>> g_plans;
uint64_t g_planned;

// the call shape's hash: 8 bytes a step (constraint texts are ~0.5 KB each, hashed on every randomize();
// a byte-wise FNV was a fifth of a call on the A72). Only a key: planMatches() compares the texts.
inline void fnv(uint64_t& h, const void* p, size_t n)
{
    const unsigned char* b = static_cast<const unsigned char*>(p);
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t w;
        std::memcpy(&w, b + i, 8);
        h = (h ^ w) * 0x9E3779B97F4A7C15ULL;
        h ^= h >> 29;
    }
    for (; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ULL; }
}

std::unordered_map<std::string, std::shared_ptr<Compiled>> g_cache;
uint64_t g_fast, g_fallback;
int g_on = -1, g_tries = 100, g_rejects = 64, g_debug;
uint64_t g_enum = 65536;    // OCV_FAST_RANDOM_ENUM: a group with at most this many combinations is enumerated

// OCV_FAST_RANDOM_DEBUG=1: say why a call went to the SMT solver (the first 20 times)
thread_local int g_quiet = 0;       // > 0: a probe solve (soft constraints): not counted, not reported
thread_local bool g_unsat = false;  // the last refusal was a proof (an empty domain, a false constant)

bool fallback(const char* why, const std::string& detail = "")
{
    if (g_quiet) {
        if (g_debug) VL_PRINTF("ocv_fast_random: (soft constraint probe) %s%s%s\n", why, detail.empty() ? "" : ": ", detail.c_str());
        return false;
    }
    g_fallback++;
    if (g_debug && g_fallback <= 20)
        VL_PRINTF("ocv_fast_random: to the SMT solver: %s%s%s\n", why, detail.empty() ? "" : ": ", detail.c_str());
    return false;
}

}  // namespace

extern "C" void ocv_fast_random_stats(uint64_t* fast, uint64_t* fallback)
{
    *fast = g_fast;
    *fallback = g_fallback;
}

bool ocv_fast_randomize(VlRandomizer& r, VlRNG& rng)
{
    if (g_on < 0) {
        const char* e = std::getenv("OCV_FAST_RANDOM");
        g_on = !(e && e[0] == '0');
        if (const char* t = std::getenv("OCV_FAST_RANDOM_TRIES")) g_tries = std::max(1, std::atoi(t));
        if (const char* t = std::getenv("OCV_FAST_RANDOM_ENUM")) g_enum = std::strtoull(t, nullptr, 0);
        const char* d = std::getenv("OCV_FAST_RANDOM_DEBUG");
        g_debug = d && d[0] == '1';
    }
    g_unsat = false;
    if (!g_on) return fallback("off (OCV_FAST_RANDOM=0)");
    if (!r.m_randcVarNames.empty()) return fallback("randc");
    if (!r.m_unique_arrays.empty()) return fallback("unique");
    if (!r.m_softConstraints.empty()) {
        // Soft constraints (IEEE 1800-2023 18.5.13), as Verilator's SMT path relaxes them: all of them
        // if they can hold together; otherwise, from the last (highest priority) to the first, each
        // one that still can with the hard ones and those kept. A soft constraint is dropped only on a
        // proof that it cannot hold (an empty domain); an unproven refusal goes to the SMT solver.
        const std::vector<std::string> hard = r.m_constraints, soft = r.m_softConstraints;
        r.m_softConstraints.clear();
        auto attempt = [&](const std::vector<std::string>& kept, bool quiet) {
            r.m_constraints = hard;
            r.m_constraints.insert(r.m_constraints.end(), kept.begin(), kept.end());
            g_quiet += quiet;
            const bool ok = ocv_fast_randomize(r, rng);
            g_quiet -= quiet;
            return ok;
        };
        auto restore = [&]() { r.m_constraints = hard; r.m_softConstraints = soft; };
        if (attempt(soft, true)) { restore(); if (!g_quiet) g_fast++; return true; }
        if (!g_unsat) { restore(); return fallback("soft constraints: no solution found with all of them"); }
        std::vector<std::string> kept;
        for (auto it = soft.rbegin(); it != soft.rend(); ++it) {
            std::vector<std::string> trial = kept;
            trial.push_back(*it);
            if (attempt(trial, true)) kept = std::move(trial);
            else if (!g_unsat) { restore(); return fallback("soft constraints: a refusal not proven"); }
        }
        const bool ok = attempt(kept, false);   // the draw itself, counted
        restore();
        return ok;
    }
    if (!r.m_solveBefore.empty()) return fallback("solve-before");
    // a known call shape, no frozen variable: draw only (VlRandomizer's members are visible here only)
    uint64_t shape = 0xcbf29ce484222325ULL;
    for (const auto& kv : r.m_vars) {
        fnv(shape, kv.first.data(), kv.first.size());
        const int w = kv.second->width();
        fnv(shape, &w, sizeof w);
    }
    for (const std::string& t : r.m_constraints) { fnv(shape, t.data(), t.size()); fnv(shape, "", 1); }
    auto planMatches = [&r](const Plan& p) {
        if (p.names.size() != r.m_vars.size() || p.texts.size() != r.m_constraints.size()) return false;
        size_t i = 0;
        for (const auto& kv : r.m_vars) {
            if (kv.first != p.names[i] || kv.second->width() != p.widths[i]) return false;
            i++;
        }
        i = 0;
        for (const std::string& t : r.m_constraints) if (t != p.texts[i++]) return false;
        return true;
    };
    {
        auto it = g_plans.find(shape);
        if (it != g_plans.end() && it->second->quick && planMatches(*it->second)) {
            Plan& p = *it->second;
            bool anyFrozen = false;
            for (const auto& kv : r.m_vars) if (r.isFrozenVar(kv.first, *kv.second)) { anyFrozen = true; break; }
            if (!anyFrozen) {
                thread_local std::vector<uint64_t> pv;
                pv.assign(p.names.size(), 0);
                g_val = pv.data();
                bool ok = true;
                for (const Plan::Group& g : p.groups) {
                    bool gok = false;
                    for (int t = 0; t < g_rejects && !gok; t++) {
                        for (int i : g.mem) pv[i] = draw(p.dom[i], rng);
                        gok = true;
                        for (const Compiled* c : g.cons) if (!eval(c->e.get(), pv.data())) { gok = false; break; }
                    }
                    if (!gok) { ok = false; p.quick = false; break; }   // tight: the full way from now on
                }
                if (ok) {
                    size_t i = 0;
                    for (const auto& kv : r.m_vars) {
                        void* d = kv.second->datap(0);
                        const int w = p.widths[i];
                        if (w <= 8) *static_cast<CData*>(d) = (CData)pv[i];
                        else if (w <= 16) *static_cast<SData*>(d) = (SData)pv[i];
                        else if (w <= 32) *static_cast<IData*>(d) = (IData)pv[i];
                        else *static_cast<QData*>(d) = pv[i];
                        i++;
                    }
                    if (!g_quiet) g_fast++;
                    g_planned++;
                    return true;
                }
            }
        }
    }
    // variables: scalars up to 64 bits; frozen ones (rand_mode off) are constants at their value
    Ctx cx;
    std::vector<const VlRandomVar*> vars;
    std::vector<char> frozen;
    std::vector<uint64_t> val;
    for (const auto& kv : r.m_vars) {
        const VlRandomVar& v = *kv.second;
        if (v.dimension() != 0 || v.width() > 64 || v.width() < 1)
            return fallback("variable is an array or wider than 64 bits", kv.first);
        cx.varIndex[kv.first] = (int)vars.size();
        cx.width.push_back(v.width());
        vars.push_back(&v);
        const bool fz = r.isFrozenVar(kv.first, v);
        frozen.push_back(fz);
        uint64_t cur = 0;
        const void* p = v.datap(0);
        if (v.width() <= 8) cur = *static_cast<const CData*>(p);
        else if (v.width() <= 16) cur = *static_cast<const SData*>(p);
        else if (v.width() <= 32) cur = *static_cast<const IData*>(p);
        else cur = *static_cast<const QData*>(p);
        val.push_back(cur & mask(v.width()));
    }
    const int nv = (int)vars.size();
    // constraints: compiled once per text (the variable numbering is part of the key)
    std::string sig;
    for (const auto& kv : r.m_vars) { sig += kv.first; sig += ':'; sig += std::to_string(kv.second->width()); sig += ' '; }
    std::vector<Set> dom(nv);
    for (int i = 0; i < nv; i++) dom[i] = frozen[i] ? Set::range(val[i], val[i]) : Set::full(cx.width[i]);
    std::vector<const Compiled*> check;
    g_val = val.data();
    g_known = frozen.data();
    for (const std::string& text : r.m_constraints) {
        if (g_cache.size() > 4096) g_cache.clear();   // constraints with ever-changing constants
        std::shared_ptr<Compiled>& c = g_cache[sig + text];
        if (!c) {
            c = std::make_shared<Compiled>();
            c->text = text;
            Sx s;
            const char* p = text.c_str();
            if (parseSx(p, s)) {
                c->e = compile(s, cx);
                if (c->e && c->e->w == 1) {          // a 1-bit vector constraint means "== 1"
                    std::unique_ptr<Expr> b{new Expr};
                    b->op = BV2B; b->w = 0; b->a.push_back(std::move(c->e));
                    c->e = std::move(b);
                }
                c->ok = c->e && c->e->w == 0;
                if (c->ok) collectVars(c->e.get(), c->vars);
            }
        }
        if (!c->ok) return fallback("constraint form not supported", text);
        int free = -1, nfree = 0;
        for (int v : c->vars) if (!frozen[v]) { free = v; nfree++; }
        Set s;
        if (nfree == 1 && boolSet(c->e.get(), free, cx.width[free], s)) {
            dom[free] = setAnd(dom[free], s);
        } else if (nfree == 0 && c->vars.empty()) {
            if (!eval(c->e.get(), val.data())) { g_unsat = true; return fallback("constraint false", text); }
        } else {
            check.push_back(c.get());
        }
    }
    for (int i = 0; i < nv; i++)
        if (dom[i].empty()) { g_unsat = true; return fallback("no value satisfies the constraints"); }
    // Variables tied by a remaining constraint form a group; groups are drawn independently, so
    // a hard group does not spoil the exact draw of an easy one.
    std::vector<int> grp(nv);
    for (int i = 0; i < nv; i++) grp[i] = i;
    std::function<int(int)> root = [&](int i) { return grp[i] == i ? i : grp[i] = root(grp[i]); };
    for (const Compiled* c : check) {
        int f = -1;
        for (int v : c->vars) {
            if (frozen[v]) continue;
            if (f < 0) f = root(v);
            else grp[root(v)] = f;
        }
    }
    // the plan of this call shape, for the next calls (no frozen variable: the sets are constants)
    if (std::find(frozen.begin(), frozen.end(), (char)1) == frozen.end() && g_plans.size() < 4096 &&
        g_plans.find(shape) == g_plans.end()) {
        std::unique_ptr<Plan> p{new Plan};
        for (const auto& kv : r.m_vars) { p->names.push_back(kv.first); p->widths.push_back(kv.second->width()); }
        for (const std::string& t : r.m_constraints) {
            p->texts.push_back(t);
            p->keep.push_back(g_cache[sig + t]);
        }
        p->dom = dom;
        for (int g = 0; g < nv; g++) {
            if (root(g) != g) continue;
            Plan::Group pg;
            for (int i = 0; i < nv; i++) if (root(i) == g) pg.mem.push_back(i);
            for (const Compiled* c : check)
                for (int v : c->vars) if (root(v) == g) { pg.cons.push_back(c); break; }
            p->groups.push_back(std::move(pg));
        }
        g_plans[shape] = std::move(p);
    }
    std::vector<char> known(frozen);
    bool found = true;
    for (int g = 0; g < nv && found; g++) {
        if (frozen[g] || root(g) != g) continue;
        std::vector<int> mem;
        for (int i = 0; i < nv; i++) if (!frozen[i] && root(i) == g) mem.push_back(i);
        std::vector<const Compiled*> cons;           // the remaining constraints of this group
        for (const Compiled* c : check)
            for (int v : c->vars) if (!frozen[v] && root(v) == g) { cons.push_back(c); break; }
        auto holds = [&]() {
            for (const Compiled* c : cons) if (!eval(c->e.get(), val.data())) return false;
            return true;
        };
        // 1. independent draws, rejected while a constraint fails: exactly uniform over the
        //    group's solutions; fine unless they are a small part of the combinations
        bool ok = false;
        for (int t = 0; t < g_rejects && !ok; t++) {
            for (int i : mem) val[i] = draw(dom[i], rng);
            ok = cons.empty() || holds();
        }
        // 2. one variable after the other, each drawn from what the constraints allow given the
        //    ones drawn before it: always a solution where one exists along this order;
        //    near-uniform (exactly uniform when every earlier choice leaves equally many ways on)
        for (int t = 0; t < g_tries && !ok; t++) {
            for (int i : mem) known[i] = 0;
            g_known = known.data();
            bool dead = false;
            for (int i : mem) {
                Set d = dom[i];
                std::vector<const Compiled*> local;   // decided by this variable, not reducible
                for (const Compiled* c : cons) {
                    bool mine = false, ready = true;
                    for (int v : c->vars) {
                        if (v == i) mine = true;
                        else if (!known[v]) ready = false;
                    }
                    if (!mine || !ready) continue;
                    Set s;
                    if (boolSet(c->e.get(), i, cx.width[i], s)) d = setAnd(d, s);
                    else local.push_back(c);
                }
                if (d.empty()) { dead = true; break; }
                bool vok = false;
                for (int k = 0; k < g_rejects && !vok; k++) {
                    val[i] = draw(d, rng);
                    vok = true;
                    for (const Compiled* c : local) if (!eval(c->e.get(), val.data())) { vok = false; break; }
                }
                if (!vok) { dead = true; break; }
                known[i] = 1;
            }
            ok = !dead && holds();
        }
        // 3. a small group (at most OCV_FAST_RANDOM_ENUM combinations, default 65536): every
        //    combination - a uniform pick among the solutions, or a proof that there is none
        if (!ok) {
            u128 combos = 1;
            for (int i : mem) {
                combos *= dom[i].size();
                if (combos > (u128)g_enum) break;
            }
            if (combos <= (u128)g_enum) {
                std::vector<size_t> ivi(mem.size(), 0);
                std::vector<uint64_t> pick(mem.size());
                for (size_t k = 0; k < mem.size(); k++) val[mem[k]] = dom[mem[k]].iv[0].first;
                uint64_t nsol = 0;
                for (bool more = true; more;) {
                    if (holds() && rng.rand64() % ++nsol == 0)          // reservoir: each solution 1/n
                        for (size_t k = 0; k < mem.size(); k++) pick[k] = val[mem[k]];
                    more = false;                                       // next combination (odometer)
                    for (size_t k = 0; k < mem.size(); k++) {
                        const Set& d = dom[mem[k]];
                        uint64_t& v = val[mem[k]];
                        if (v < d.iv[ivi[k]].second) { v++; more = true; break; }
                        if (ivi[k] + 1 < d.iv.size()) { v = d.iv[++ivi[k]].first; more = true; break; }
                        ivi[k] = 0;
                        v = d.iv[0].first;
                    }
                }
                if (nsol == 0) { g_known = nullptr; g_unsat = true; return fallback("no combination satisfies the constraints"); }
                for (size_t k = 0; k < mem.size(); k++) val[mem[k]] = pick[k];
                ok = true;
            }
        }
        found = ok;
    }
    g_known = nullptr;
    if (!found && g_debug && g_fallback < 20) {
        for (const Compiled* c : check)
            if (!eval(c->e.get(), val.data())) VL_PRINTF("ocv_fast_random:   fails: %s\n", c->text.c_str());
        int i = 0;
        for (const auto& kv : r.m_vars) {
            VL_PRINTF("ocv_fast_random:   %s = 0x%llx, set of %zu interval(s) from 0x%llx\n", kv.first.c_str(),
                      (unsigned long long)val[i], dom[i].iv.size(),
                      dom[i].iv.empty() ? 0ULL : (unsigned long long)dom[i].iv[0].first);
            i++;
        }
    }
    if (found) {
        for (int i = 0; i < nv; i++) {
            if (frozen[i]) continue;
            void* p = vars[i]->datap(0);
            const int w = cx.width[i];
            if (w <= 8) *static_cast<CData*>(p) = (CData)val[i];
            else if (w <= 16) *static_cast<SData*>(p) = (SData)val[i];
            else if (w <= 32) *static_cast<IData*>(p) = (IData)val[i];
            else *static_cast<QData*>(p) = val[i];
        }
        if (!g_quiet) g_fast++;
        return true;
    }
    return fallback("no solution found (OCV_FAST_RANDOM_TRIES rounds)");
}

// ---- the test's result, for the exit code (tools/verilator/uvm_z_exit_status.patch, uvm/vlt/ocv_main.cpp) ----
// UVM's run_test (and die) report the server's UVM_ERROR and UVM_FATAL counts here after the summary.
// (It lives in this file because every OCV build of the patched UVM compiles this file.)
int ocv_uvm_errors = -1;                       // -1: run_test did not end (no summary)
extern "C" void ocv_uvm_result(int errors, int fatals) { ocv_uvm_errors = errors + fatals; }
