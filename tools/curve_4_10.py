#!/usr/bin/env python3
"""curve_4_10.py - FOCUS 4.10: the board's gain against the DUT's clocks per transaction of the test.

Reads the points (docs/wiki/curve-4-10.csv: measured on the board, measured on the PC, estimated by the model) and
draws them with the model of FOCUS 4.10 as an SVG (no matplotlib needed):

    t_pc    ~ clocks * c_clk                          (c_clk: the PC's price of one DUT clock, grows with the DUT)
    t_board ~ max(N_tr * c_tr + clocks * c_arm, clocks / f_fpga)
              (c_tr: the A72's price of one transaction of the test - a UVM item; c_arm: its price per DUT clock of
              what grows with the records, not the items: the hub's bus words, the C model - 0 if not known)
    gain    = t_pc / t_board = k * c_clk / max(c_tr + k * c_arm, k / f_fpga),   k = clocks / N_tr

    tools/curve_4_10.py [--csv docs/wiki/curve-4-10.csv] [-o build/curve_4_10.svg]

The model lines are drawn for the c_clk of each DUT that has a point (from its row: c_clk_us) with the c_tr of its
row (c_tr_us, c_arm_us); a point's own gain is its measurement (or its estimate, marked as such).
"""
import argparse, csv, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OCV = os.path.dirname(HERE)
F_FPGA = 50e6

KIND_STYLE = {   # kind -> (marker, fill, label)
    "board": ("circle", "#1f6fb2", "измерено на плате"),
    "model": ("diamond", "#ffffff", "ПК измерен, плата — оценка по модели"),
}
COLORS = ["#1f6fb2", "#c0392b", "#27ae60", "#8e44ad", "#d98c1f", "#16a085", "#7f8c8d"]


def model_gain(k, c_clk_us, c_tr_us, c_arm_us=0.0, f=F_FPGA):
    return k * c_clk_us / max(c_tr_us + k * (c_arm_us or 0.0), k / f * 1e6)


def load(path):
    rows = []
    with open(path) as fh:
        for r in csv.DictReader(fh):
            if not r["point"] or r["point"].startswith("#"):
                continue
            for k in ("k_clk_per_tr", "gain", "c_clk_us", "c_tr_us", "c_arm_us"):
                r[k] = float(r[k]) if r.get(k) not in (None, "", "-") else None
            rows.append(r)
    return rows


def svg(rows, out):
    W, H, L, R, T, B = 1000, 560, 80, 330, 30, 60
    xs = [r["k_clk_per_tr"] for r in rows]
    gs = [r["gain"] for r in rows]
    x0, x1 = 10 ** math.floor(math.log10(min(xs) / 2)), 10 ** math.ceil(math.log10(max(xs) * 20))
    y0, y1 = 10 ** math.floor(math.log10(min(gs) / 2)), 10 ** math.ceil(math.log10(max(gs) * 2))

    def X(v): return L + (math.log10(v) - math.log10(x0)) / (math.log10(x1) - math.log10(x0)) * (W - L - R)
    def Y(v): return H - B - (math.log10(v) - math.log10(y0)) / (math.log10(y1) - math.log10(y0)) * (H - T - B)

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="sans-serif" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="#fff"/>']
    for e in range(int(math.log10(x0)), int(math.log10(x1)) + 1):
        v = 10 ** e
        o.append(f'<line x1="{X(v):.1f}" y1="{T}" x2="{X(v):.1f}" y2="{H-B}" stroke="#ddd"/>'
                 f'<text x="{X(v):.1f}" y="{H-B+16}" text-anchor="middle">{v:g}</text>')
    for e in range(int(math.log10(y0)), int(math.log10(y1)) + 1):
        v = 10 ** e
        o.append(f'<line x1="{L}" y1="{Y(v):.1f}" x2="{W-R}" y2="{Y(v):.1f}" stroke="#ddd"/>'
                 f'<text x="{L-6}" y="{Y(v)+4:.1f}" text-anchor="end">×{v:g}</text>')
    o.append(f'<line x1="{L}" y1="{Y(1):.1f}" x2="{W-R}" y2="{Y(1):.1f}" stroke="#555" stroke-dasharray="4 3"/>')
    o.append(f'<text x="{(L+W-R)/2}" y="{H-18}" text-anchor="middle">тактов DUT на транзакцию теста (k)</text>')
    o.append(f'<text x="18" y="{(T+H-B)/2}" text-anchor="middle" transform="rotate(-90 18 {(T+H-B)/2})">'
             'выигрыш платы (время ПК / время платы)</text>')
    # model lines: one per DUT with its c_clk and c_tr
    duts = []
    for r in rows:
        if r["c_clk_us"] and r["c_tr_us"] and r["dut"] not in [d[0] for d in duts]:
            duts.append((r["dut"], r["c_clk_us"], r["c_tr_us"], r["c_arm_us"]))
    col = {d[0]: COLORS[i % len(COLORS)] for i, d in enumerate(duts)}
    for d, cc, ct, ca in duts:
        pts, n = [], 60
        for i in range(n + 1):
            k = 10 ** (math.log10(x0) + i / n * (math.log10(x1) - math.log10(x0)))
            g = model_gain(k, cc, ct, ca)
            if y0 <= g <= y1:
                pts.append(f"{X(k):.1f},{Y(g):.1f}")
        if pts:
            o.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="{col[d]}" stroke-width="1.2" '
                     f'stroke-dasharray="6 3" opacity="0.7"/>')
    for r in rows:
        x, y = X(r["k_clk_per_tr"]), Y(r["gain"])
        shape, fill, _ = KIND_STYLE[r["kind"]]
        c = col.get(r["dut"], "#333")
        f = c if r["kind"] == "board" else ("#fff" if r["kind"] == "model" else c)
        if shape == "circle":
            o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{f}" stroke="{c}" stroke-width="1.5"/>')
        elif shape == "square":
            o.append(f'<rect x="{x-4.5:.1f}" y="{y-4.5:.1f}" width="9" height="9" fill="{f}" stroke="{c}" '
                     f'stroke-width="1.5" opacity="0.8"/>')
        else:
            o.append(f'<polygon points="{x:.1f},{y-6:.1f} {x+6:.1f},{y:.1f} {x:.1f},{y+6:.1f} {x-6:.1f},{y:.1f}" '
                     f'fill="{f}" stroke="{c}" stroke-width="1.5"/>')
        if r.get("label"):
            o.append(f'<text x="{x+8:.1f}" y="{y-6:.1f}" font-size="10" fill="#333">{r["label"]}</text>')
    # legend
    ly = T + 10
    for kind, (shape, fill, lab) in KIND_STYLE.items():
        o.append(f'<text x="{W-R+12}" y="{ly}" font-size="11">{"●" if shape=="circle" else "■" if shape=="square" else "◇"} {lab}</text>')
        ly += 18
    ly += 8
    for d, cc, ct, ca in duts:
        o.append(f'<line x1="{W-R+12}" y1="{ly-4}" x2="{W-R+36}" y2="{ly-4}" stroke="{col[d]}" stroke-dasharray="6 3"/>'
                 f'<text x="{W-R+40}" y="{ly}" font-size="10">модель: {d} (c_clk {cc:g} мкс, c_tr {ct:g}{f" + k·{ca:g}" if ca else ""} мкс)</text>')
        ly += 16
    o.append(f'<text x="{W-R+12}" y="{ly+10}" font-size="10">f ПЛИС = {F_FPGA/1e6:g} МГц</text>')
    o.append("</svg>")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, "w").write("\n".join(o) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--csv", default=os.path.join(OCV, "docs", "wiki", "curve-4-10.csv"))
    ap.add_argument("-o", "--out", default=os.path.join(OCV, "build", "curve_4_10.svg"))
    a = ap.parse_args()
    rows = load(a.csv)
    if not rows:
        sys.exit("curve_4_10: no points")
    print(f"{'point':34} {'kind':6} {'k':>10} {'gain':>8} {'model':>8}")
    for r in rows:
        m = model_gain(r["k_clk_per_tr"], r["c_clk_us"], r["c_tr_us"], r["c_arm_us"]) if r["c_clk_us"] and r["c_tr_us"] else None
        print(f"{r['point']:34} {r['kind']:6} {r['k_clk_per_tr']:10.4g} {r['gain']:8.3g} "
              f"{(f'{m:8.3g}' if m else '       -')}")
    svg(rows, a.out)
    print(f"curve_4_10: {len(rows)} points -> {a.out}")


if __name__ == "__main__":
    main()
