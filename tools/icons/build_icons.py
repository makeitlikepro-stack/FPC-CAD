#!/usr/bin/env python3
"""FPC-CAD icons from Tabler Icons (MIT), offline after the checkout.

    python3 tools/icons/build_icons.py --source /path/to/tabler-icons

--source: a checkout of https://github.com/tabler/tabler-icons (icons/outline
and LICENSE are read). tools/icons/cad_icons.json maps icon keys to Tabler
names. Output (replaces the folder): assets/icons/
  png/<size>/<key>.png for sizes 20 and 24, stroke colour baked in
  LICENSE (Tabler MIT text), SOURCE.txt (commit)
Raster: librsvg + cairo through ctypes (the engine's SVG backend).
"""
import argparse, ctypes, json, re, shutil, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "icons"
MAP = Path(__file__).with_name("cad_icons.json")
SIZES = (20, 24)
COLOR = "#2B2F36"        # dark grey strokes on light buttons
STROKE = "1.75"


class Rect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double),
                ("w", ctypes.c_double), ("h", ctypes.c_double)]


def rasterize(svg: bytes, size: int, out: Path) -> None:
    r = ctypes.CDLL("librsvg-2.so.2")
    c = ctypes.CDLL("libcairo.so.2")
    vp = ctypes.c_void_p
    r.rsvg_handle_new_from_data.restype = vp
    r.rsvg_handle_new_from_data.argtypes = [ctypes.c_char_p, ctypes.c_size_t, vp]
    r.rsvg_handle_render_document.argtypes = [vp, vp, ctypes.POINTER(Rect), vp]
    c.cairo_image_surface_create.restype = vp
    c.cairo_create.restype = vp
    c.cairo_create.argtypes = [vp]
    c.cairo_surface_write_to_png.argtypes = [vp, ctypes.c_char_p]
    c.cairo_destroy.argtypes = [vp]
    c.cairo_surface_destroy.argtypes = [vp]
    h = r.rsvg_handle_new_from_data(svg, len(svg), None)
    if not h:
        raise SystemExit("librsvg could not read an icon")
    surf = c.cairo_image_surface_create(0, size, size)   # CAIRO_FORMAT_ARGB32
    cr = c.cairo_create(surf)
    r.rsvg_handle_render_document(h, cr, ctypes.byref(Rect(0, 0, size, size)), None)
    c.cairo_surface_write_to_png(surf, str(out).encode())
    c.cairo_destroy(cr)
    c.cairo_surface_destroy(surf)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    src = Path(ap.parse_args().source)
    icons = json.loads(MAP.read_text())["icons"]
    if OUT.exists():
        shutil.rmtree(OUT)
    for size in SIZES:
        (OUT / "png" / str(size)).mkdir(parents=True)
    for key, name in icons.items():
        svg = (src / "icons" / "outline" / f"{name}.svg").read_text()
        svg = svg.replace("currentColor", COLOR)
        svg = re.sub(r'stroke-width="[0-9.]+"', f'stroke-width="{STROKE}"', svg)
        for size in SIZES:
            rasterize(svg.encode(), size, OUT / "png" / str(size) / f"{key}.png")
    shutil.copy(src / "LICENSE", OUT / "LICENSE")
    commit = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    (OUT / "SOURCE.txt").write_text(f"Tabler Icons (MIT) https://github.com/tabler/tabler-icons commit {commit}\n")
    print(f"{len(icons)} icons x {len(SIZES)} sizes -> {OUT}")


if __name__ == "__main__":
    main()
