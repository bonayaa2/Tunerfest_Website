"""Add photos to the TunerFest gallery.

Usage: python3 tools/add_photos.py batch.json
batch.json is a list of {"src": "/path/to/photo.jpg", "cap": "Caption", "tag": "builds|crowd|action|details|night|bikes"}.

Each photo becomes assets/gallery/pNNN.webp (full size, for the viewer) and
pNNN-sm.webp (grid size), is appended to gallery.json, and the list is written
into index.html between the PHOTOS markers.
"""
import json, sys, re
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "gallery"
MANIFEST = ROOT / "gallery.json"
PAGE = ROOT / "index.html"
TAGS = {"builds", "crowd", "action", "details", "night", "bikes"}

def save(im, path, long_edge, quality):
    im = im.copy()
    im.thumbnail((long_edge, long_edge), Image.LANCZOS)
    im.save(path, "WEBP", quality=quality, method=6)
    return im.size

def main(batch_file):
    batch = json.loads(Path(batch_file).read_text())
    photos = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else []
    n = max([int(p["id"][1:]) for p in photos] or [0])
    for item in batch:
        assert item["tag"] in TAGS, item
        n += 1
        pid = f"p{n:03d}"
        im = ImageOps.exif_transpose(Image.open(item["src"])).convert("RGB")
        w, h = save(im, OUT / f"{pid}.webp", 1800, 80)
        sw, sh = save(im, OUT / f"{pid}-sm.webp", 760, 74)
        photos.append({"id": pid, "cap": item["cap"], "tag": item["tag"], "w": w, "h": h, "sw": sw, "sh": sh})
        print(pid, item["tag"], f"{w}x{h}", item["cap"])
    MANIFEST.write_text(json.dumps(photos, indent=1))
    page = PAGE.read_text()
    data = json.dumps(photos, separators=(",", ":"))
    page, k = re.subn(r"/\*PHOTOS\*/.*?/\*END PHOTOS\*/", lambda m: f"/*PHOTOS*/{data}/*END PHOTOS*/", page, flags=re.S)
    assert k == 1, "PHOTOS markers not found in index.html"
    PAGE.write_text(page)
    print(f"{len(photos)} photos in gallery")

if __name__ == "__main__":
    main(sys.argv[1])
