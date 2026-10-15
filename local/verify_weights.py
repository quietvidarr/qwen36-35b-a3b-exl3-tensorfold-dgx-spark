#!/usr/bin/env python3
"""Verify the HF-cache copy of the pinned weights against local/manifest.json: every listed file present with its size
and digest (sha256 for LFS files, git-blob sha1 for small git files), following the cache's symlinks.
  local/verify_weights.py          full check (reads ~27 GB, a minute or two)
  local/verify_weights.py --quick  sizes only"""
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HUB = Path(os.environ.get("HF_HUB_CACHE", Path.home() / ".cache/huggingface/hub"))

m = json.loads((ROOT / "local" / "manifest.json").read_text())
pins = dict(line.split("=", 1) for line in (ROOT / "local" / "pins.env").read_text().split("\n")
            if "=" in line and not line.startswith("#"))
if (m["repo"], m["revision"]) != (pins["MODEL_REPO"], pins["MODEL_REVISION"]):
    sys.exit(f"local/manifest.json is for {m['repo']}@{m['revision']}, pins.env says "
             f"{pins['MODEL_REPO']}@{pins['MODEL_REVISION']}: run local/pin-weights.sh")
snap = HUB / f"models--{m['repo'].replace('/', '--')}" / "snapshots" / m["revision"]
quick = "--quick" in sys.argv
bad = total = 0
for item in m["files"]:
    p = snap / item["path"]
    total += item["bytes"]
    if not p.is_file():
        print(f"MISSING {item['path']}"); bad += 1; continue
    if p.stat().st_size != item["bytes"]:
        print(f"SIZE    {item['path']} {p.stat().st_size} != {item['bytes']}"); bad += 1; continue
    if quick:
        continue
    h = hashlib.sha256() if item["algorithm"] == "sha256" else hashlib.sha1()
    if item["algorithm"] == "git-blob-sha1":
        h.update(f"blob {item['bytes']}\0".encode())
    with open(p, "rb") as f:
        while chunk := f.read(16 << 20):
            h.update(chunk)
        try:                                   # leave the page cache to the running model (unified memory)
            os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        except (AttributeError, OSError):
            pass
    if h.hexdigest() != item["digest"]:
        print(f"DIGEST  {item['path']}"); bad += 1
print(f"{m['repo']}@{m['branch']} {m['revision'][:12]}: {len(m['files'])} files, {total / 2**30:.2f} GiB: "
      f"{'OK' if not bad else f'{bad} problem(s)'}{' (sizes only)' if quick else ''} ({snap})")
sys.exit(1 if bad else 0)
