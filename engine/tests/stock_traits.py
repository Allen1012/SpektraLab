"""Measure the film and paper cards' traits (PRD/PRD-胶片指南卡片与风格.md appendix A).

Writes `modern_UI/stock_traits.json`, which `Tools/gen-catalog.py` folds into
the app's catalogue and turns into five dots per trait -- linear over the
measured range, films and papers apart, never quantiles.

    engine/build.sh dylib
    python3 engine/tests/stock_traits.py            # needs nothing but this repository

Every stochastic effect is off except where named (AGENTS.md trap 1), and so is
auto exposure: the inputs are already placed on the meter's axis. The DIR
couplers stay on -- they are part of every film's default look. A silver film is
sent the way the app sends it: grade 2's filter pack, its own grain
(`FilmParams.ownGrain`), the single-layer grain model.

- contrast   -- print density of a grey ramp, slope over -1..+1 EV around 18 %
                (density per decade of scene exposure). A film on its declared
                paper, a slide film scanned; a paper under a fixed reference
                film -- Portra 400 for colour, Tri-X 400 for silver -- so that
                papers differ by the paper alone.
- saturation -- twelve hues at L* 50 and C*ab 25, every patch at mid-grey's
                lightness: the mean output C*ab over 25. Same pairings as
                contrast. Rendered to linear ProPhoto RGB, so nothing is clipped
                to a display gamut before it is measured. Not for silver stocks.
- latitude   -- the film alone, scanned: the span of scene EV, contiguous around
                mid-grey, over which the film's own density gradient stays at
                least half its gradient at mid-grey, on a ramp of +-12 EV. A
                span that outlasts the ramp or the 16-bit output is reported
                with a warning, as a floor. Films only.
- grain      -- RMS of print density over a flat 18 % grey with grain on, x1000,
                on a 2000x3000 frame (grain averages away on a small one). Films
                only. The colour negatives share one grain model today
                (research/colour-film-granularity.md §3), so they measure alike.

## Why not the first version's method (2026-10-13)

Its first run disagreed with the card copy in five places, and three causes
were the method, not the renderer:

- Saturation used four patches near the sRGB gamut's edge, at four different
  lightnesses. A patch at the edge cannot get more saturated, a dark one sits
  where colour dies first (trap 31), and a stiffer print darkens it further --
  so the paper with more contrast measured less saturated (Ultra Endura last).
  The hue ring holds lightness at mid-grey's and stays well inside the gamut.
- A paper was measured under whichever film declares it (2383 under Verita,
  Portra Endura under Ektar), so papers differed by film as much as by paper.
- Latitude was `spk_scene_latitude`'s medium, which for a negative is the
  negative *and* its paper: every silver film on grade 2 read 6.2-6.6 stops,
  and a slide's scan could not be compared with a print at all. A film's card
  describes the film, so latitude is now the film's own curve.
"""
import argparse, datetime, json, sys, tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402
from bw_checks import overlay, QUIET, P, density  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json"
OUT = REPO / "modern_UI/stock_traits.json"
ENGINE = REPO / "engine"
REF_COLOUR_FILM = "kodak_portra_400"
REF_SILVER_FILM = "kodak_tri_x_400"
TRAIT_QUIET = {k: v for k, v in QUIET.items() if k != "dir_couplers_active"}
OWN_GRAIN = {"kodak_tri_x_400": 1.70, "ilford_hp5_plus_400": 1.49, "kodak_tmax_100": 0.74,
             "fujifilm_neopan_acros_100_ii": 0.64}
GRAIN_FRAME = (2000, 3000)
LATITUDE_EV = np.arange(-12.0, 12.001, 0.25)
LINEAR_PROPHOTO = {"output_color_space": "ProPhoto RGB", "output_cctf_encoding": False}
RING_CHROMA = 25.0

D65 = np.array([0.95047, 1.0, 1.08883])
SRGB_TO_XYZ = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
# ProPhoto RGB (ROMM) is D50; Bradford takes its XYZ to D65 to compare with the input.
PROPHOTO_TO_XYZ_D50 = np.array([[0.7976749, 0.1351917, 0.0313534], [0.2880402, 0.7118741, 0.0000857],
                                [0.0, 0.0, 0.8252100]])
BRADFORD_D50_TO_D65 = np.array([[0.9555766, -0.0230393, 0.0631636], [-0.0282895, 1.0099416, 0.0210077],
                                [0.0122982, -0.0204830, 1.3299098]])


def xyz_to_lab(xyz):
    t = np.asarray(xyz, float) / D65
    f = np.where(t > (6 / 29) ** 3, np.cbrt(t), t / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def lab_to_xyz(lab):
    lab = np.asarray(lab, float)
    fy = (lab[..., 0] + 16) / 116
    f = np.stack([fy + lab[..., 1] / 500, fy, fy - lab[..., 2] / 200], -1)
    return np.where(f > 6 / 29, f ** 3, 3 * (6 / 29) ** 2 * (f - 4 / 29)) * D65


def hue_ring(n=12, lightness=50.0, chroma=RING_CHROMA):
    """`n` hues at one lightness and one chroma, as linear sRGB inside the gamut."""
    h = np.radians(np.arange(n) * 360.0 / n)
    lab = np.stack([np.full(n, lightness), chroma * np.cos(h), chroma * np.sin(h)], -1)
    rgb = lab_to_xyz(lab) @ np.linalg.inv(SRGB_TO_XYZ).T
    assert rgb.min() > 0 and rgb.max() < 1, "the hue ring left the sRGB gamut"
    return rgb.astype(np.float32)


RING = hue_ring()


def render(e, img, delta):
    s = e.open(img, {**TRAIT_QUIET, **delta})
    try:
        rgba, _ = s.render("full")
    finally:
        s.close()
    return rgba[..., :3].astype(np.float64) / 65535.0


def cells(v, n):
    return np.array([v[8:-8, i * P + 8:(i + 1) * P - 8].mean((0, 1)) for i in range(n)])


def ramp(stops):
    row = np.repeat(0.184 * 2.0 ** np.asarray(stops, float), P)
    return np.tile(row[None, :, None], (P, 1, 3)).astype(np.float32)


def strip(colours):
    img = np.zeros((P, P * len(colours), 3), np.float32)
    for i, c in enumerate(colours):
        img[:, i * P:(i + 1) * P] = c
    return img


def latitude(e, film):
    """The film's own span, and whether it ran off the ramp (then it is a floor)."""
    v = cells(render(e, ramp(LATITUDE_EV), {"film_stock": film, "scan_film": True,
                                            "output_cctf_encoding": False}), len(LATITUDE_EV))[:, 1]
    floor = 2 / 65535
    d = -np.log10(np.maximum(v, floor))
    g = np.abs(np.gradient(d, LATITUDE_EV))
    i0 = int(np.argmin(np.abs(LATITUDE_EV)))
    threshold = 0.5 * g[i0]
    # A sample at either end of the 16-bit range has no gradient to speak of.
    ok = (g >= threshold) & (v > floor) & (v < 0.999)

    def edge(inside, step):
        outside = inside + step
        while 0 <= outside < len(g) and ok[outside]:
            inside, outside = outside, outside + step
        if not 0 <= outside < len(g):
            return LATITUDE_EV[inside], True
        # Clipping is the 16-bit output's limit, not the film's.
        if not floor < v[outside] < 0.999:
            return LATITUDE_EV[inside], True
        a, b = g[inside], g[outside]
        f = (a - threshold) / (a - b) if a != b else 0.0
        return LATITUDE_EV[inside] + f * (LATITUDE_EV[outside] - LATITUDE_EV[inside]), False

    hi, top = edge(i0, +1)
    lo, bottom = edge(i0, -1)
    return float(hi - lo), top or bottom


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path, default=None)
    a = ap.parse_args()
    stocks = json.loads(CATALOG.read_text())["stocks"]
    by_id = {s["id"]: s for s in stocks}
    grades = json.loads((ENGINE / "resources_product" / "paper_grades.json").read_text())["grades"]

    def pairing(stock):
        """(film, paper or None for a scan, what the card says it was measured with)."""
        if stock["stage"] == "filming":
            if stock.get("type") == "positive" or not stock.get("targetPrint"):
                return stock["id"], None, "scan"
            return stock["id"], stock["targetPrint"], stock["targetPrint"]
        film = REF_SILVER_FILM if stock.get("monochrome") else REF_COLOUR_FILM
        return film, stock["id"], film

    out = {}
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=a.dylib, resources=overlay(tmp)) as e:
        for stock in stocks:
            film, paper, measured_with = pairing(stock)
            silver = by_id[film].get("monochrome", False)
            delta = {"film_stock": film}
            if paper is None:
                delta["scan_film"] = True
            else:
                delta["print_stock"] = paper
            if silver:
                delta.update(grades["2"])
                delta.update({"c_filter_neutral": 0.0, "grain_sublayers_active": False,
                              "grain_amount": OWN_GRAIN.get(film, 1.0)})
            t = {"measuredWith": measured_with}

            d = density(cells(render(e, ramp([-1.0, 0.0, 1.0]), delta), 3).mean(1))
            t["contrast"] = float((d[0] - d[2]) / (2 * np.log10(2.0)))

            if not silver:
                rgb = cells(render(e, strip(RING), {**delta, **LINEAR_PROPHOTO}), len(RING))
                lab = xyz_to_lab(rgb @ PROPHOTO_TO_XYZ_D50.T @ BRADFORD_D50_TO_D65.T)
                t["saturation"] = float(np.hypot(lab[:, 1], lab[:, 2]).mean() / RING_CHROMA)

            if stock["stage"] == "filming":
                span, ran_off = latitude(e, film)
                if ran_off:
                    print(f"warning: {film}'s latitude reached the ramp's end; {span:.2f} is a floor")
                t["latitude"] = span
                h, w = GRAIN_FRAME
                flat = np.full((h, w, 3), 0.184, np.float32)
                v = render(e, flat, {**delta, "grain_active": True})[h // 2 - 512:h // 2 + 512,
                                                                     w // 2 - 512:w // 2 + 512].mean(2)
                t["grain"] = float(density(v).std() * 1000)

            out[stock["id"]] = t
            print(stock["id"], {k: round(v, 3) if isinstance(v, float) else v for k, v in t.items()})

    doc = {"version": 2, "measured": datetime.date.today().isoformat(), "stocks": out}
    OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {OUT.relative_to(REPO)} ({len(out)} stocks); now run Tools/gen-catalog.py")


if __name__ == "__main__":
    main()
