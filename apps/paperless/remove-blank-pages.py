#!/usr/bin/env python3
"""Paperless pre-consume script: drop near-empty pages of a scanned PDF.

The scanner's own blank page skip lets backs through that carry only a grey
fold shadow or the letter showing through. Each page is rendered in grey at a
low resolution, a margin is cropped (scanner edge artefacts) and the share of
clearly dark pixels is counted; pages below the minimum are removed. The first
page (the ASN sticker) is always kept, and so is at least one page. Any error
leaves the file untouched and exits 0, so consumption is never blocked.

Environment (all optional):
  DOCUMENT_WORKING_PATH            file to edit, set by Paperless
  PAPERLESS_BLANK_PAGE_MIN_INK     minimum share of dark pixels, default 0.0001
  PAPERLESS_BLANK_PAGE_DARK_LEVEL  pixels below this grey value (0-255) count
                                   as ink, default 128
  PAPERLESS_BLANK_PAGE_DPI         render resolution, default 60
  PAPERLESS_BLANK_PAGE_MARGIN      share of the page cropped on every side,
                                   default 0.05
  PAPERLESS_BLANK_PAGE_MODE        off | dry-run | on, default on
"""
import glob
import os
import subprocess
import sys
import tempfile


def log(msg):
    print("remove-blank-pages: " + msg, flush=True)


def main():
    mode = os.environ.get("PAPERLESS_BLANK_PAGE_MODE", "on").strip().lower()
    if mode == "off":
        return
    path = os.environ.get("DOCUMENT_WORKING_PATH", "")
    if not path or not os.path.isfile(path):
        log("no DOCUMENT_WORKING_PATH, skipping")
        return
    with open(path, "rb") as f:
        if f.read(5) != b"%PDF-":
            return

    min_ink = float(os.environ.get("PAPERLESS_BLANK_PAGE_MIN_INK", "0.0001"))
    dark = int(os.environ.get("PAPERLESS_BLANK_PAGE_DARK_LEVEL", "128"))
    dpi = int(os.environ.get("PAPERLESS_BLANK_PAGE_DPI", "60"))
    margin = float(os.environ.get("PAPERLESS_BLANK_PAGE_MARGIN", "0.05"))

    import pikepdf
    from PIL import Image

    with pikepdf.open(path) as pdf:
        count = len(pdf.pages)
        if count < 2:
            return

        remove = []
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(
                ["pdftoppm", "-gray", "-r", str(dpi), path, tmp + "/p"],
                check=True, timeout=240,
            )
            files = sorted(glob.glob(tmp + "/p-*"))
            if len(files) != count:
                log("rendered %d of %d pages, skipping" % (len(files), count))
                return
            for index, name in enumerate(files):
                with Image.open(name) as img:
                    width, height = img.size
                    crop = int(min(width, height) * margin)
                    hist = img.crop(
                        (crop, crop, width - crop, height - crop)
                    ).histogram()
                ink = sum(hist[:dark]) / max(sum(hist), 1)
                blank = index > 0 and ink < min_ink
                log("page %d: ink %.5f%s" % (
                    index + 1, ink,
                    " (first page, kept)" if index == 0
                    else " -> blank" if blank else ""))
                if blank:
                    remove.append(index)

        if not remove:
            return
        if mode != "on":
            log("dry run, would remove pages %s" % [i + 1 for i in remove])
            return
        for index in reversed(remove):
            del pdf.pages[index]
        out = path + ".blank-tmp"
        try:
            pdf.save(out)
            os.replace(out, path)
        finally:
            if os.path.exists(out):
                os.remove(out)
        log("removed pages %s, %d left" % (
            [i + 1 for i in remove], count - len(remove)))


try:
    main()
except Exception as exc:
    log("error, file left untouched: %r" % (exc,))
sys.exit(0)
