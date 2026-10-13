"""Measure the film and paper cards' traits (PRD/PRD-胶片指南卡片与风格.md appendix A).

Writes `modern_UI/stock_traits.json`, which `Tools/gen-catalog.py` folds into
the app's catalogue and turns into five dots per trait — linear over the
measured range, films and papers apart, never quantiles.

    engine/build.sh dylib
    python3 engine/tests/stock_traits.py            # needs nothing but this repository

What is measured, every stochastic effect off except where named:

- contrast   -- print density of a grey ramp, slope over -1..+1 EV around 18 %
                (density per decade of scene exposure), on the stock's default
                pairing: a film on its declared paper, a paper under a reference film.
- saturation -- mean C*ab of four coloured patches on the print, over their
                C*ab as they went in. Not measured for black-and-white stocks.
- latitude   -- `spk_scene_latitude`'s `medium.latitude_stops`. Films only.
- grain      -- RMS of print density over a flat 18 % grey with grain on, x1000.
                Films only. The colour negatives share one grain model today
                (research/colour-film-granularity.md §3), so expect them close.

**Not yet run** (2026-10-12): written on a machine without Xcode, so the dylib
could not be built. The first run is the check that the request keys and the
`scene_latitude` reply's shape are what this file assumes.
"""
import argparse, json, sys, tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402
from bw_checks import overlay, QUIET, PATCHES, P, density  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json"
OUT = REPO / "modern_UI/stock_traits.json"
ENGINE = REPO / "engine"
REF_COLOUR_FILM = "kodak_portra_400"
REF_SILVER_FILM = "kodak_tri_x_400"
COLOURS = [k for k in PATCHES if k != "grey"]


def srgb_to_lab(enc):
    """sRGB-encoded (…, 3) to CIELAB, D65."""
    enc = np.asarray(enc, float)
    lin = np.where(enc <= 0.04045, enc / 12.92, ((enc + 0.055) / 1.055) ** 2.4)
    return linear_to_lab(lin)


def linear_to_lab(lin):
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = np.asarray(lin, float) @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def chroma(lab):
    return np.hypot(lab[..., 1], lab[..., 2])


def render(e, img, delta):
    s = e.open(img, {**QUIET, **delta})
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


def chart(names):
    img = np.zeros((P, P * len(names), 3), np.float32)
    for i, k in enumerate(names):
        img[:, i * P:(i + 1) * P] = PATCHES[k]
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path, default=None)
    a = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    stocks = catalog["stocks"] if isinstance(catalog, dict) else catalog
    by_id = {s["id"]: s for s in stocks}
    grades = json.loads((ENGINE / "resources_product" / "paper_grades.json").read_text())["grades"]

    def pairing(stock):
        """(film, paper or None for a scan, extra wire fields, measuredWith)."""
        mono = stock.get("monochrome", False)
        if stock["stage"] == "filming":
            film, paper = stock["id"], stock.get("targetPrint")
            if stock.get("type") == "positive" or not paper:
                return film, None, {}, "scan"
            return film, paper, (grades["2"] if mono else {}), paper
        paper = stock["id"]
        partners = [s["id"] for s in stocks if s["stage"] == "filming" and s.get("targetPrint") == paper]
        film = partners[0] if partners else (REF_SILVER_FILM if mono else REF_COLOUR_FILM)
        return film, paper, (grades["2"] if mono else {}), film

    out = {}
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=a.dylib, resources=overlay(tmp)) as e:
        for stock in stocks:
            film, paper, extra, measured_with = pairing(stock)
            delta = {"film_stock": film, **extra}
            if paper is None:
                delta["scan_film"] = True
            else:
                delta["print_stock"] = paper
                if extra:
                    delta["c_filter_neutral"] = 0.0
            mono = stock.get("monochrome", False) or by_id.get(film, {}).get("monochrome", False)
            t = {"measuredWith": measured_with}

            grey = cells(render(e, ramp([-1.0, 0.0, 1.0]), delta), 3).mean(1)
            d = density(grey)
            t["contrast"] = float((d[0] - d[2]) / (2 * np.log10(2.0)))

            if not mono:
                rendered = chroma(srgb_to_lab(cells(render(e, chart(COLOURS), delta), len(COLOURS))))
                source = chroma(linear_to_lab(np.array([PATCHES[k] for k in COLOURS])))
                t["saturation"] = float(np.mean(rendered / source))

            if stock["stage"] == "filming":
                s = e.open(ramp([0.0]), {**QUIET, **delta})
                try:
                    t["latitude"] = float(s.scene_latitude()["medium"]["latitude_stops"])
                finally:
                    s.close()
                flat = np.full((256, 256, 3), 0.184, np.float32)
                v = render(e, flat, {**delta, "grain_active": True})[16:-16, 16:-16].mean(2)
                t["grain"] = float(density(v).std() * 1000)

            out[stock["id"]] = t
            print(stock["id"], {k: round(v, 3) if isinstance(v, float) else v for k, v in t.items()})

    OUT.write_text(json.dumps({"version": 1, "stocks": out}, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {OUT.relative_to(REPO)} ({len(out)} stocks); now run Tools/gen-catalog.py")


if __name__ == "__main__":
    main()
