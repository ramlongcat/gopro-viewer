#!/usr/bin/env python3
"""GoPro camera emulator for developing GoProViewer without a real camera.

Serves the subset of the Open GoPro wired HTTP API the app uses, backed by a
folder of media files (any GoPro-named MP4/JPG/LRV/THM/GPR files work; other
.mp4/.jpg files get synthetic GoPro names). GPS telemetry (gopro/media/gpmf)
is synthesized deterministically per file so the map inspector has data.

Usage:
    tools/gopro_emulator.py --library ~/Movies/GoPro
    then set Settings → Camera IP override to 127.0.0.1 in the app.

The app always talks to port 8080, so keep the default port. With an empty or
missing --library, a small synthetic photo library is generated (no videos —
drop real MP4s in to test playback).
"""
import argparse
import hashlib
import json
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

FOLDER = "100GOPRO"
MEDIA = {}          # "100GOPRO/GX010001.MP4" -> Path (everything servable)
MAINS = []          # media-list entries (dicts), sorted by name
MP4_META = {}       # Path -> {"dur": float|None, "w": int|None, "h": int|None}
CACHE = Path.home() / "Library/Caches/GoProEmulator"
ARGS = None

# ---------------------------------------------------------------- MP4 parsing

def _mp4_boxes(f, start, end):
    off = start
    while off + 8 <= end:
        f.seek(off)
        head = f.read(8)
        if len(head) < 8:
            return
        size, typ = struct.unpack(">I4s", head)
        hdr = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            hdr = 16
        elif size == 0:
            size = end - off
        if size < hdr:
            return
        yield typ, off + hdr, off + size
        off += size

def mp4_meta(path):
    """Duration (s) and video track dimensions, tolerant of anything weird."""
    meta = {"dur": None, "w": None, "h": None}
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            moov = next(((s, e) for t, s, e in _mp4_boxes(f, 0, size) if t == b"moov"), None)
            if not moov:
                return meta
            for t, s, e in _mp4_boxes(f, *moov):
                if t == b"mvhd":
                    f.seek(s)
                    v = f.read(1)[0]
                    f.seek(s + (12 if v == 0 else 20))
                    ts = struct.unpack(">I", f.read(4))[0]
                    dur = struct.unpack(">I" if v == 0 else ">Q", f.read(4 if v == 0 else 8))[0]
                    if ts:
                        meta["dur"] = dur / ts
                elif t == b"trak":
                    for t2, s2, _ in _mp4_boxes(f, s, e):
                        if t2 == b"tkhd" and meta["w"] is None:
                            f.seek(s2)
                            v = f.read(1)[0]
                            f.seek(s2 + (76 if v == 0 else 88))
                            w, h = struct.unpack(">II", f.read(8))
                            w, h = w >> 16, h >> 16
                            if w and h:
                                meta["w"], meta["h"] = w, h
    except Exception:
        pass
    return meta

# ---------------------------------------------------------------- GPMF (GPS)

def _klv(fourcc, typ, ssize, repeat, payload):
    t = typ if isinstance(typ, int) else ord(typ)
    head = fourcc.encode() + bytes([t, ssize]) + struct.pack(">H", repeat)
    return head + payload + b"\x00" * ((-len(payload)) % 4)

def gpmf_for(name, dur):
    """Deterministic ~10 Hz GPS5 walk near the Seine, chunked like real GPMF."""
    rnd = random.Random(zlib.crc32(name.encode()))
    n = max(30, int((dur or 60) * 10))
    lat = 48.8584 + rnd.uniform(-0.01, 0.01)
    lon = 2.2945 + rnd.uniform(-0.01, 0.01)
    heading = rnd.uniform(0, 2 * math.pi)
    out = bytearray()
    done = 0
    while done < n:
        chunk = min(18, n - done)
        samples = bytearray()
        for _ in range(chunk):
            heading += rnd.uniform(-0.15, 0.15)
            speed = max(0.5, min(9.0, rnd.gauss(4, 2)))
            lat += math.cos(heading) * speed * 0.1 / 111_111
            lon += math.sin(heading) * speed * 0.1 / 75_000
            samples += struct.pack(">5i", int(lat * 1e7), int(lon * 1e7),
                                   int(35_000 + rnd.uniform(-2000, 2000)),
                                   int(speed * 1000), int(speed * 1050))
        strm = (_klv("SCAL", "l", 4, 5, struct.pack(">5i", 10_000_000, 10_000_000, 1000, 1000, 100))
                + _klv("GPSF", "L", 4, 1, struct.pack(">I", 3))
                + _klv("GPSP", "S", 2, 1, struct.pack(">H", rnd.randint(120, 300)))
                + _klv("GPS5", "l", 20, chunk, bytes(samples)))
        strm_box = _klv("STRM", 0, 1, len(strm), strm)
        out += _klv("DEVC", 0, 1, len(strm_box), strm_box)
        done += chunk
    return bytes(out)

# ------------------------------------------------------------- library scan

def make_png(w, h, hue):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    raw = bytearray()
    for y in range(h):
        raw += b"\x00"
        for x in range(w):
            raw += bytes((int(hue[0] * (0.3 + 0.7 * x / w)),
                          int(hue[1] * (0.3 + 0.7 * (1 - y / h))),
                          int(hue[2] * (0.4 + 0.6 * y / h))))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw)))
            + chunk(b"IEND", b""))

def make_synthetic_library(root):
    root.mkdir(parents=True, exist_ok=True)
    hues = [(240, 90, 60), (60, 200, 120), (70, 120, 250), (250, 200, 60), (200, 70, 220), (90, 220, 230)]
    now = time.time()
    for i, hue in enumerate(hues):
        p = root / f"GP01000{i + 1}.JPG"
        p.write_bytes(make_png(640, 480, hue))
        # two capture "days"
        stamp = now - (86400 * 2 if i < 3 else 86400) + i * 600
        os.utime(p, (stamp, stamp))
    print(f"library was empty — generated {len(hues)} synthetic photos in {root}")
    print("drop real GoPro .MP4/.JPG files there (or use --library ~/Movies/GoPro) to test video playback")

GOPRO_VIDEO = re.compile(r"^G[A-Z]\d{6}$")
GOPRO_PHOTO = re.compile(r"^GP?[A-Z]?\d{6,7}$")

def scan_library(root):
    exts = {".MP4", ".JPG", ".LRV", ".THM", ".GPR", ".360"}
    all_files = [p for p in sorted(root.rglob("*"))
                 if p.is_file() and p.suffix.upper() in exts and not p.name.startswith(".")]
    if not all_files:
        make_synthetic_library(root)
        all_files = sorted(root.glob("*.JPG"))

    by_name = {}
    synth = 9000
    for p in all_files:
        name = p.name.upper()
        stem = p.stem.upper()
        # non-GoPro-named main media get synthetic camera names
        if p.suffix.upper() in (".MP4", ".360") and not GOPRO_VIDEO.match(stem):
            synth += 1
            name = f"GX01{synth}.MP4"
        elif p.suffix.upper() == ".JPG" and not (GOPRO_VIDEO.match(stem) or GOPRO_PHOTO.match(stem)):
            synth += 1
            name = f"GP01{synth}.JPG"
        if name not in by_name:      # camera names are unique; skip duplicates
            by_name[name] = p

    for name, p in by_name.items():
        MEDIA[f"{FOLDER}/{name}"] = p

    for name, p in sorted(by_name.items()):
        ext = Path(name).suffix.upper()
        if ext not in (".MP4", ".360", ".JPG"):
            continue                 # LRV/THM/GPR are served, not listed
        st = p.stat()
        entry = {"n": name, "cre": str(int(st.st_mtime)), "mod": str(int(st.st_mtime)), "s": str(st.st_size)}
        base = Path(name).stem
        if ext in (".MP4", ".360"):
            lrv_key = f"{FOLDER}/GL{base[2:]}.LRV"
            if lrv_key not in MEDIA:
                # A real camera always keeps an .LRV beside each clip, and the
                # app asks for it by name (hover previews in the grid). A
                # library of transferred files usually has none, so stand the
                # main file in for it rather than leaving those paths 404.
                MEDIA[lrv_key] = p
            entry["glrv"] = str(MEDIA[lrv_key].stat().st_size)
            MP4_META[p] = mp4_meta(p)
        elif f"{FOLDER}/{base}.GPR" in MEDIA:
            entry["raw"] = "1"
        MAINS.append(entry)

def add_fake_items(n):
    """Synthetic photos served from the cache, deliberately absent from the
    library/destination — keeps the "not transferred yet" state reachable."""
    fake_dir = CACHE / "fake"
    fake_dir.mkdir(parents=True, exist_ok=True)
    hues = [(250, 120, 40), (40, 180, 250), (180, 250, 90), (250, 80, 180)]
    now = time.time()
    for i in range(n):
        name = f"GP01{9901 + i}.JPG"
        key = f"{FOLDER}/{name}"
        if key in MEDIA:
            continue
        p = fake_dir / name
        if not p.exists():
            p.write_bytes(make_png(640, 480, hues[i % len(hues)]))
        stamp = now - i * 60
        os.utime(p, (stamp, stamp))
        MEDIA[key] = p
        st = p.stat()
        MAINS.append({"n": name, "cre": str(int(st.st_mtime)),
                      "mod": str(int(st.st_mtime)), "s": str(st.st_size)})

# ---------------------------------------------------------------- thumbnails

def _crop_to_aspect(out, want):
    """Center-crop like camera firmware does (photo thumbs are 4:3)."""
    try:
        r = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(out)],
                           capture_output=True, text=True, timeout=10)
        w = h = None
        for line in r.stdout.splitlines():
            if "pixelWidth:" in line:
                w = int(line.split()[-1])
            elif "pixelHeight:" in line:
                h = int(line.split()[-1])
        if not w or not h or abs(w / h - want) < 0.02:
            return
        if w / h > want:
            nw, nh = int(h * want), h
        else:
            nw, nh = w, int(w / want)
        subprocess.run(["sips", "-c", str(nh), str(nw), str(out)], capture_output=True, timeout=10)
    except Exception:
        pass

def thumbnail(path_key, px):
    src = MEDIA[path_key]
    CACHE.mkdir(parents=True, exist_ok=True)
    out = CACHE / f"{px}-{src.stem}.png"
    if not out.exists():
        try:
            if src.suffix.upper() in (".MP4", ".360"):
                with tempfile.TemporaryDirectory() as td:
                    subprocess.run(["qlmanage", "-t", f"-s{px}", "-o", td, str(src)],
                                   capture_output=True, timeout=30)
                    made = list(Path(td).glob("*.png"))
                    if made:
                        shutil.copy(made[0], out)
            else:
                subprocess.run(["sips", "-Z", str(px), str(src), "--out", str(out)],
                               capture_output=True, timeout=30)
                _crop_to_aspect(out, 4 / 3)   # real cameras serve 4:3 photo thumbs
        except Exception:
            pass
    if out.exists():
        return out.read_bytes()
    return make_png(480, 270, (90, 90, 96))   # placeholder

# ------------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "GoProEmulator/1.0"

    def log_message(self, fmt, *args):
        if not ARGS.quiet:
            sys.stderr.write("  %s\n" % (fmt % args))

    def send_json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_bytes(self, data, ctype="application/octet-stream"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_file_ranged(self, path):
        size = path.stat().st_size
        start, end = 0, size - 1
        status = 200
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                else:
                    start = max(0, size - int(m.group(2)))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4" if path.suffix.upper() in (".MP4", ".LRV", ".360") else "image/jpeg")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        budget = ARGS.throttle * 1024 * 1024 if ARGS.throttle else None
        with open(path, "rb") as f:
            f.seek(start)
            left = length
            t0 = time.monotonic()
            sent = 0
            while left > 0:
                data = f.read(min(256 * 1024, left))
                if not data:
                    break
                self.wfile.write(data)
                left -= len(data)
                sent += len(data)
                if budget:
                    ahead = sent / budget - (time.monotonic() - t0)
                    if ahead > 0:
                        time.sleep(ahead)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        p = url.path
        if ARGS.latency:
            time.sleep(ARGS.latency / 1000)

        if p == "/gopro/version":
            return self.send_json({"version": "2.0"})
        if p in ("/gopro/camera/control/wired_usb", "/gopro/media/turbo_transfer",
                 "/gopro/camera/keep_alive"):
            return self.send_json({})
        if p == "/gopro/camera/info":
            return self.send_json({"model_name": "HERO13 Black (emulated)",
                                   "serial_number": "EMU0000000001",
                                   "firmware_version": "H24.01-EMU"})
        if p == "/gopro/camera/state":
            used = sum(v.stat().st_size for v in MEDIA.values()) // 1024
            # 256 GB card. It has to be bigger than the library being served,
            # or the app is fed negative free space.
            cap = 256 * 1024 * 1024
            return self.send_json({"status": {"70": ARGS.battery, "54": cap - used,
                                              "117": cap, "8": 0, "10": 0}})
        if p == "/gopro/media/list":
            return self.send_json({"id": "EMU-1", "media": [{"d": FOLDER, "fs": MAINS}]})
        if p == "/gopro/media/info":
            key = q.get("path", "")
            src = MEDIA.get(key)
            if not src:
                return self.send_error(404)
            is_video = src.suffix.upper() in (".MP4", ".360")
            # Field names and value encodings follow GoPro's own SDK
            # (wsdk .../entity/operation/Media.kt) so the app's metadata
            # inspector is exercised the same way a real camera exercises it.
            out = {
                "s": str(src.stat().st_size),
                "cre": str(int(src.stat().st_mtime)),
                "gumi": hashlib.md5(str(src).encode()).hexdigest(),
                "ct": "0" if is_video else "4",
                "lc": "0",
                "prjn": "9",
                "hc": "0",
                "eis": "0",
                "mp": "0",
                "tr": "0",
                "us": "0",
                "mos": [],
                "rot": "0",
            }
            meta = MP4_META.get(src)
            if is_video:
                out.update({"ao": "stereo", "pta": "1", "cl": "0", "prog": "1",
                            "subsample": "0", "avc_profile": "255", "profile": "255",
                            "fps": "30000", "fps_denom": "1001"})
                lrv = MEDIA.get(f"{FOLDER}/GL{Path(key).stem[2:]}.LRV")
                out["ls"] = str(lrv.stat().st_size) if lrv else "0"
            else:
                out.update({"raw": "0", "wdr": "0", "hdr": "0"})
            if meta:
                if meta["dur"]:
                    out["dur"] = f"{meta['dur']:.3f}"
                    num = int(Path(key).stem[4:] or 0)
                    if num % 2 == 0:   # every other video gets demo HiLights
                        out["hi"] = [str(int(meta["dur"] * 250)), str(int(meta["dur"] * 600))]
                        out["hc"] = "2"
                if meta["w"]:
                    out["w"], out["h"] = str(meta["w"]), str(meta["h"])
                out["eis"] = "1"
            return self.send_json(out)
        if p in ("/gopro/media/thumbnail", "/gopro/media/screennail"):
            key = q.get("path", "")
            if key not in MEDIA:
                return self.send_error(404)
            px = 360 if p.endswith("thumbnail") else 1024
            return self.send_bytes(thumbnail(key, px), "image/png")
        if p == "/gopro/media/gpmf":
            key = q.get("path", "")
            src = MEDIA.get(key)
            if not src or src.suffix.upper() not in (".MP4", ".360"):
                return self.send_error(404)
            dur = (MP4_META.get(src) or {}).get("dur")
            return self.send_bytes(gpmf_for(Path(key).name, dur))
        if p.startswith("/videos/DCIM/"):
            key = p[len("/videos/DCIM/"):]
            src = MEDIA.get(key)
            if not src:
                return self.send_error(404)
            return self.send_file_ranged(src)
        self.send_error(404)

def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", default="tools/emulator-library",
                    help="folder of media to serve (default: tools/emulator-library, auto-populated)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080, help="the app always dials 8080")
    ap.add_argument("--battery", type=int, default=82)
    ap.add_argument("--fake", type=int, default=1,
                    help="synthetic photos not present in the library, so the app "
                         "always sees untransferred items (default 1; 0 = none)")
    ap.add_argument("--throttle", type=float, default=0, help="cap media downloads, MB/s (0 = none)")
    ap.add_argument("--latency", type=float, default=0, help="added per-request latency, ms")
    ap.add_argument("--quiet", action="store_true")
    ARGS = ap.parse_args()

    scan_library(Path(ARGS.library).expanduser())
    if ARGS.fake > 0:
        add_fake_items(ARGS.fake)
    videos = sum(1 for e in MAINS if e["n"].endswith((".MP4", ".360")))
    print(f"serving {len(MAINS)} items ({videos} videos, {len(MAINS) - videos} photos) "
          f"from {Path(ARGS.library).expanduser()}"
          + (f" + {ARGS.fake} fake (never-transferred)" if ARGS.fake > 0 else ""))
    print(f"emulated GoPro on http://{ARGS.host}:{ARGS.port}")
    if ARGS.host == "127.0.0.1" and ARGS.port == 8080:
        print("GoProViewer ≥1.5.0 discovers this automatically (a real camera wins if present)")
    else:
        print("non-default host/port: set Settings → Connection → Camera IP override = " + ARGS.host)
    srv = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")

if __name__ == "__main__":
    main()
