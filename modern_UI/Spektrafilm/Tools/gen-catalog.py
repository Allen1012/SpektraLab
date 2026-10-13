#!/usr/bin/env python3
"""Build Resources/StockCatalog.json and Resources/FilmCovers/ from the engine's
profile library, so the app never parses the 5.6 MB of sensitometric JSON.

    Tools/gen-catalog.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]

# Read from the engine's own baked resources, not from the Python reference
# tree under `src/`. This is the difference the standalone repo makes: `src/`
# is not here, and `engine/resources/` is — the same 28 profiles the engine
# opens at run time, plus `print_luts.json`, which is the metadata index over
# the 8 print-preview LUTs (`paired_film`, `lut_size`, and so on) that the bake
# wrote. Deriving the catalog from the engine's inputs means the catalog cannot
# disagree with what the engine will actually load.
PROFILES = REPO / "engine/resources/profiles"
# The product's own profiles (black and white), which `engine/build.sh bundle`
# lays into the same directory in the app. Listed here with `monochrome` set,
# and offered only where `FeatureFlags.blackAndWhite` is on.
PRODUCT_PROFILES = REPO / "engine/resources_product/profiles"
PRINT_LUTS = REPO / "engine/resources/print_luts.json"
COVERS_SRC = REPO / "modern_UI/film_covers"
OUT = HERE / "Spektrafilm/Resources"
# PRD/PRD-胶片指南卡片与风格.md §6: the card copy (hand-written), the measured
# traits (`engine/tests/stock_traits.py`, absent until it has been run) and
# the designer's illustrations (`<id>.svg`, absent until they are drawn).
GUIDE = REPO / "modern_UI/stock_guide.json"
TRAITS = REPO / "modern_UI/stock_traits.json"
ART_SRC = REPO / "modern_UI/stock_art"

# The scene vocabulary, in the order the filter shows it (PRD §4.2). Four are
# derived from data below; the rest come only from the guide's hand-written tags.
SCENES = ["portrait", "landscape", "everyday", "lowLight", "tungsten", "cinematic", "vintage", "bw"]
TRAIT_KEYS = ["contrast", "saturation", "latitude", "grain"]


def film_speed(name: str) -> int | None:
    """The ISO in a film's name: "Portra 400" 400, "Vision3 250D" 250, "C200"
    200, "Pro 400H" 400. A single digit (Vision3, HP5) is not a speed."""
    m = re.search(r"(?<!\d)(\d{2,4})(?:[A-Z]{0,2})?(?![\d])", name.replace("Vision3", "Vision"))
    return int(m.group(1)) if m else None


def push_stops(sid: str) -> int | None:
    m = re.search(r"_push(\d)$", sid)
    return int(m.group(1)) if m else None


def derived_scenes(entry: dict, info: dict) -> list[str]:
    """The tags the data decides, so nobody has to keep them in step by hand."""
    out = []
    if entry["stage"] != "filming":
        return out
    if (entry.get("iso") or 0) >= 500 or entry.get("push"):
        out.append("lowLight")
    if info.get("reference_illuminant") == "T":
        out.append("tungsten")
    if entry["use"] == "cine":
        out.append("cinematic")
    if entry.get("monochrome"):
        out.append("bw")
    return out


def levels(stocks: list[dict]) -> None:
    """Five dots per trait, **linear over the measured range**, films and papers
    apart. Not quantiles: a quantile spreads stocks that measure the same over
    all five dots, and the colour negatives' grain is exactly that case
    (research/colour-film-granularity.md §3), so a quantile would invent a
    difference the picture does not have."""
    for stage in ("filming", "printing"):
        group = [s for s in stocks if s["stage"] == stage and "traits" in s]
        for key in TRAIT_KEYS:
            vals = [s["traits"][key]["value"] for s in group if key in s["traits"]]
            if not vals:
                continue
            lo, hi = min(vals), max(vals)
            for s in group:
                t = s["traits"].get(key)
                if t is not None:
                    t["level"] = 3 if hi - lo < 1e-9 else 1 + round(4 * (t["value"] - lo) / (hi - lo))

# stock id -> substring of the cover filename
COVERS = {
    "kodak_portra_400": "Kodak_Portra_400",
    "kodak_portra_160": "Kodak_Portra_160",
    "kodak_portra_800": "Kodak_Portra_800",
    "kodak_portra_800_push1": "Kodak_Portra_800",
    "kodak_portra_800_push2": "Kodak_Portra_800",
    "kodak_gold_200": "Kodak_Gold_200",
    "kodak_ektachrome_100": "Kodak_Ektachrome_100",
    "kodak_ultramax_400": "Kodak_UltraMax_400",
    "fujifilm_provia_100f": "Fujifilm_Provia_100F",
    "fujifilm_velvia_100": "Fujifilm_Velvia_100",
    "fujifilm_xtra_400": "Fujifilm_Color_400",
}


# Film stock -> the film gauges its manufacturer made it in, ever (current or
# discontinued; third-party respooling does not count). From
# SpektraLab_mobile/research/overscan/availability.md (2026-10-01), where every
# cell is sourced; that table is the reference, this is its "yes" and
# "discontinued" cells. Gauges: "135", "120", "16mm", "super8", "35mm_motion".
# Format availability is not profile data (RFC-032 §22), so it lives here and
# not in the CC BY-SA profiles. A stock missing from this table gets no
# `formats` key, which the app reads as "not known: offer every format".
FORMATS = {
    "fujifilm_c200": ["135"],
    "fujifilm_pro_400h": ["135", "120"],
    "fujifilm_provia_100f": ["135", "120"],
    "fujifilm_velvia_100": ["135", "120"],
    "fujifilm_xtra_400": ["135", "120"],
    "kodak_ektachrome_100": ["135", "120", "16mm", "super8"],
    "kodak_ektar_100": ["135", "120"],
    "kodak_gold_200": ["135", "120"],
    "kodak_kodachrome_64": ["135", "120"],
    "kodak_portra_160": ["135", "120"],
    "kodak_portra_400": ["135", "120"],
    "kodak_portra_800": ["135", "120"],
    "kodak_portra_800_push1": ["135", "120"],
    "kodak_portra_800_push2": ["135", "120"],
    "kodak_ultramax_400": ["135"],
    "kodak_verita_200d": ["16mm", "35mm_motion"],
    "kodak_vision3_200t": ["16mm", "super8", "35mm_motion"],
    "kodak_vision3_250d": ["16mm", "35mm_motion"],
    "kodak_vision3_500t": ["16mm", "super8", "35mm_motion"],
    "kodak_vision3_50d": ["16mm", "super8", "35mm_motion"],
    # the black-and-white films: each maker's own sheet lists 135 and 120
    "kodak_tri_x_400": ["135", "120"],
    "kodak_tmax_100": ["135", "120"],
    "fujifilm_neopan_acros_100_ii": ["135", "120"],
    "ilford_hp5_plus_400": ["135", "120"],
}


def main() -> None:
    (OUT / "FilmCovers").mkdir(parents=True, exist_ok=True)
    luts = json.loads(PRINT_LUTS.read_text())
    guide = json.loads(GUIDE.read_text())["stocks"] if GUIDE.exists() else {}
    traits = json.loads(TRAITS.read_text())["stocks"] if TRAITS.exists() else {}
    art_out = OUT / "StockArt"
    if ART_SRC.is_dir() and any(ART_SRC.glob("*.svg")):
        art_out.mkdir(parents=True, exist_ok=True)
    stocks = []
    for path in sorted([*PROFILES.glob("*.json"), *PRODUCT_PROFILES.glob("*.json")], key=lambda f: f.stem):
        info = json.loads(path.read_text())["info"]
        sid = path.stem
        cover = None
        if sid in COVERS:
            src = next(COVERS_SRC.glob(f"*{COVERS[sid]}*"), None)
            if src:
                cover = f"{sid}.jpg"
                dst = OUT / "FilmCovers" / cover
                if not dst.exists():
                    subprocess.run(["sips", "-Z", "160", str(src), "--out", str(dst)],
                                   check=True, capture_output=True)
        entry = {
            "id": sid,
            "name": info.get("name", sid),
            "stage": info.get("stage"),            # filming | printing
            "use": info.get("use", "still"),       # still | cine
            "type": info.get("type"),
            "targetPrint": info.get("target_print"),
            "hasPreviewLUT": sid in luts,
            "pairedFilm": luts[sid]["paired_film"] if sid in luts else None,
            "cover": cover,
        }
        if info.get("channel_model") == "bw":
            entry["monochrome"] = True         # one silver emulsion (a film) or a silver paper
        if sid in FORMATS:
            entry["formats"] = FORMATS[sid]
        if entry["stage"] == "filming":
            iso = film_speed(entry["name"])
            if iso:
                entry["iso"] = iso
            if push_stops(sid):
                entry["push"] = push_stops(sid)
        if info.get("reference_illuminant"):
            entry["illuminant"] = info["reference_illuminant"]
        if info.get("antihalation"):
            entry["antihalation"] = info["antihalation"]
        g = guide.get(sid)
        if g is not None:
            entry["guide"] = {"status": g.get("status", "draft"), "en": g.get("en", ""), "zh": g.get("zh", "")}
            tags = set(g.get("tags", [])) | set(derived_scenes(entry, info))
            unknown = tags - set(SCENES)
            if unknown:
                raise SystemExit(f"{sid}: unknown scene tags {sorted(unknown)}")
            if entry["stage"] == "filming":
                entry["tags"] = [s for s in SCENES if s in tags]
        else:
            print(f"warning: {sid} has no entry in {GUIDE.name}")
        t = traits.get(sid)
        if t is not None:
            entry["traits"] = {k: {"value": float(t[k])} for k in TRAIT_KEYS if t.get(k) is not None}
            if t.get("measuredWith"):
                entry["traits"]["measuredWith"] = t["measuredWith"]
        art = ART_SRC / f"{sid}.svg"
        if art.exists():
            shutil.copyfile(art, art_out / art.name)
            entry["art"] = art.name
        stocks.append(entry)
    levels(stocks)
    (OUT / "StockCatalog.json").write_text(json.dumps({"stocks": stocks}, indent=1, ensure_ascii=False))
    print(f"wrote {len(stocks)} stocks ({sum('guide' in s for s in stocks)} with a guide, "
          f"{sum('traits' in s for s in stocks)} with traits, {sum('art' in s for s in stocks)} with art)")


if __name__ == "__main__":
    main()
