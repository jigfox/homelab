#!/usr/bin/env python3
"""One-off import of the Arq 5 "Pictures" backup into Immich.

Restores every photo/video under Photos/ from the encrypted backup, builds XMP
sidecars (Lightroom catalog data + a "Quelle/Arq/<dir>" source tag), uploads
through the Immich API (skipping what is already there by SHA1) and sorts the
files into one album per event folder.

Environment: ARQ_PASSWORD, ARQ_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
IMMICH_API_KEY; optional IMMICH_URL, DRY_RUN=1, WORKERS, STAGE_DIR, LRCAT_PATH
(use a local catalog instead of restoring it), SAMPLE_DIR (dry run: write sample
sidecars there).
"""
import collections
import concurrent.futures
import datetime
import http.client
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arq5  # noqa: E402
import sidecar  # noqa: E402

PICTURES = "2DCA415A-4A60-417B-B97D-22CF388E0027"   # /Volumes/Pictures
LIGHTROOM = "F5B5DD8F-9623-4ED7-8BC0-6E861B7B5D19"  # Lightroom catalog folder
CATALOG_PATH = "Lightroom Catalog-2.lrcat"
PHOTOS = "Photos"
EXCLUDED_DIRS = {"Backup notassd"}  # directly below Photos/
MEDIA_EXT = {"jpg", "jpeg", "nef", "dng", "cr2", "tif", "tiff", "png", "heic",
             "mov", "mp4", "avi", "m4v", "3gp", "mts"}
# album names that are only a date: 2014, 2014-11, 2014-11-02, 2014-11-02 1930
DATE_ONLY = re.compile(r"\d{4}([-._]\d{1,2}){0,3}( ?\d{4})?")
JOBS_PAUSE = ["videoConversion", "smartSearch", "faceDetection", "facialRecognition", "ocr",
              "duplicateDetection"]
JOBS_START = ["smartSearch", "faceDetection", "ocr", "duplicateDetection", "videoConversion"]
ATTEMPTS = 5
ALBUM_FLUSH = 200


def log(msg):
    print(f"{datetime.datetime.now():%H:%M:%S} {msg}", flush=True)


def gib(n):
    return f"{n / 2**30:.2f} GiB"


# ---- Immich API -----------------------------------------------------------------

class ApiError(Exception):
    pass


class Immich:
    def __init__(self, base, key):
        u = urllib.parse.urlparse(base)
        self.host, self.port, self.prefix = u.hostname, u.port or 80, u.path.rstrip("/")
        self.tls = u.scheme == "https"
        self.key = key

    def _conn(self, timeout):
        cls = http.client.HTTPSConnection if self.tls else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=timeout)

    def _retry(self, fn):
        for attempt in range(1, ATTEMPTS + 1):
            try:
                return fn()
            except (OSError, http.client.HTTPException, ApiError) as e:
                retryable = not isinstance(e, ApiError) or getattr(e, "retry", False)
                if not retryable or attempt == ATTEMPTS:
                    raise
                wait = min(120, 5 * 2 ** attempt)
                log(f"API retry {attempt}/{ATTEMPTS} in {wait}s: {type(e).__name__}: {str(e)[:120]}")
                time.sleep(wait)

    @staticmethod
    def _result(status, body):
        if status in (200, 201, 204):
            return json.loads(body) if body else None
        e = ApiError(f"HTTP {status}: {body[:200]!r}")
        e.retry = status >= 500 or status == 429
        raise e

    def call(self, method, path, body=None):
        def once():
            c = self._conn(120)
            try:
                data = json.dumps(body).encode() if body is not None else None
                c.request(method, self.prefix + path, data,
                          {"x-api-key": self.key, "content-type": "application/json",
                           "accept": "application/json"})
                r = c.getresponse()
                return self._result(r.status, r.read())
            finally:
                c.close()
        return self._retry(once)

    def upload(self, fields, sha1, file_path, file_name, sidecar_bytes):
        """Multipart POST /assets, streaming the file from disk. Returns (status, id)."""
        boundary = uuid.uuid4().hex
        pre = b""
        for k, v in fields.items():
            pre += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n').encode()

        def part_head(name, fname):
            fname = fname.replace('"', "%22").replace("\r", "%0D").replace("\n", "%0A")
            return (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
                    f'filename="{fname}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()

        head = pre + part_head("assetData", file_name)
        size = os.path.getsize(file_path)
        mid = b"\r\n"
        tail = b""
        if sidecar_bytes is not None:
            tail += part_head("sidecarData", file_name + ".xmp") + sidecar_bytes + b"\r\n"
        tail += f"--{boundary}--\r\n".encode()
        total = len(head) + size + len(mid) + len(tail)

        def once():
            c = self._conn(1800)
            try:
                c.putrequest("POST", self.prefix + "/assets")
                for k, v in {"x-api-key": self.key, "x-immich-checksum": sha1,
                             "content-type": f"multipart/form-data; boundary={boundary}",
                             "content-length": str(total), "accept": "application/json"}.items():
                    c.putheader(k, v)
                c.endheaders()
                c.send(head)
                with open(file_path, "rb") as f:
                    while chunk := f.read(1 << 20):
                        c.send(chunk)
                c.send(mid + tail)
                r = c.getresponse()
                res = self._result(r.status, r.read())
                return res["status"], res["id"]
            finally:
                c.close()
        return self._retry(once)


# ---- catalog --------------------------------------------------------------------

def read_catalog(path, backup_paths):
    """Items for every master image whose file exists in the backup, plus problems."""
    db = sqlite3.connect(path)
    keywords = collections.defaultdict(list)
    for img, name in db.execute(
            "SELECT ki.image, k.name FROM AgLibraryKeywordImage ki "
            "JOIN AgLibraryKeyword k ON k.id_local = ki.tag ORDER BY k.name"):
        kw = sidecar.clean_keyword(name or "")
        if kw:
            keywords[img].append(kw)
    captions = {img: cap for img, cap in db.execute(
        "SELECT image, caption FROM AgLibraryIPTC WHERE caption IS NOT NULL AND caption != ''")}
    xmps = {}
    rows = db.execute(
        "SELECT i.id_local, i.rating, i.pick, rf.absolutePath, f.pathFromRoot, af.baseName, af.extension, "
        "a.xmp FROM Adobe_images i "
        "JOIN AgLibraryFile af ON af.id_local = i.rootFile "
        "JOIN AgLibraryFolder f ON f.id_local = af.folder "
        "JOIN AgLibraryRootFolder rf ON rf.id_local = f.rootFolder "
        "LEFT JOIN Adobe_AdditionalMetadata a ON a.image = i.id_local "
        "WHERE i.masterImage IS NULL ORDER BY rf.absolutePath, f.pathFromRoot, af.baseName")
    lower = {p.lower(): p for p in backup_paths}
    items, missing, out_of_scope, seen = [], [], 0, set()
    for img, rating, pick, root, rel, base, ext, blob in rows:
        if ".lrdata" in root:
            out_of_scope += 1
            continue
        # /Volumes/Pictures/2014/ -> Photos/2014/ ; .../Pictures/Addis iPhone/ -> Photos/Addis iPhone/
        top = root.rstrip("/").rsplit("/", 1)[-1]
        name = f"{base}.{ext}" if ext else base
        guess = f"{PHOTOS}/{top}/{rel}{name}"
        path = lower.get(guess.lower())
        if path is None:
            missing.append(guess)
            continue
        if path in seen:
            continue
        seen.add(path)
        xmp = zlib.decompress(blob[4:]).decode("utf-8", "replace") if blob else None
        items.append(dict(path=path, kind="catalog", rejected=pick == -1, rating=rating or 0,
                          keywords=keywords.get(img, []), caption=captions.get(img), xmp=xmp))
    return items, missing, out_of_scope


# ---- planning -------------------------------------------------------------------

def album_for(path):
    parts = path.split("/")  # Photos, top, [event, ...], file
    if len(parts) < 3:
        return None
    if re.fullmatch(r"\d{4}", parts[1]):
        name = parts[2] if len(parts) >= 4 else None
    else:
        name = parts[1]
    if not name or DATE_ONLY.fullmatch(name):
        return None
    return name


def walk_photos(repo, commit):
    root = repo.find(commit, PHOTOS)
    files = {}

    def walk(node, prefix):
        for name, n in sorted(repo.tree(node["keys"][0], node["ctype"]).items()):
            path = f"{prefix}/{name}"
            if n["is_tree"]:
                if prefix == PHOTOS and name in EXCLUDED_DIRS:
                    continue
                walk(n, path)
            else:
                files[path] = n
    walk(root, PHOTOS)
    return files


def build_plan(files, catalog_items):
    plan = []
    used = set()
    for it in catalog_items:
        it["node"] = files[it["path"]]
        used.add(it["path"])
        plan.append(it)
    leftovers = 0
    for path, node in files.items():
        name = path.rsplit("/", 1)[-1]
        if path in used or name.startswith(".") or "." not in name:
            continue
        if name.rsplit(".", 1)[1].lower() not in MEDIA_EXT:
            continue
        plan.append(dict(path=path, kind="leftover", rejected=False, node=node))
        leftovers += 1
    for it in plan:
        directory = it["path"].rsplit("/", 1)[0]
        tag = sidecar.source_tag(directory)
        it["album"] = album_for(it["path"])
        it["name"] = it["path"].rsplit("/", 1)[-1]
        if it["kind"] == "catalog" and it["xmp"]:
            it["sidecar"] = sidecar.from_catalog(it["xmp"], it["keywords"], it["caption"], it["rating"], tag)
        else:
            it["sidecar"] = sidecar.minimal(tag)  # leftovers, or no catalog XMP
        it["has_kw"] = bool(it.pop("keywords", None))
        it["has_cap"] = bool(it.pop("caption", None))
        it.pop("xmp", None)
    plan.sort(key=lambda i: i["path"])
    return plan


# ---- albums ---------------------------------------------------------------------

class Albums:
    def __init__(self, api):
        self.api, self.lock = api, threading.Lock()
        self.ids, self.pending, self.added = {}, collections.defaultdict(list), collections.Counter()
        self.created = set()
        self.existing = {}
        if api:
            for a in api.call("GET", "/albums"):
                self.existing.setdefault(a["albumName"], a["id"])

    def _id(self, name):
        if name not in self.ids:
            if name in self.existing:
                self.ids[name] = self.existing[name]
            else:
                self.ids[name] = self.api.call("POST", "/albums", {"albumName": name})["id"]
                self.created.add(name)
                log(f"album created: {name}")
        return self.ids[name]

    def add(self, name, asset_id):
        with self.lock:
            self.pending[name].append(asset_id)
            if len(self.pending[name]) >= ALBUM_FLUSH:
                self._flush(name)

    def _flush(self, name):
        ids, self.pending[name] = self.pending[name], []
        if not ids:
            return
        res = self.api.call("PUT", f"/albums/{self._id(name)}/assets", {"ids": ids})
        bad = [r for r in res if not r.get("success") and r.get("error") != "duplicate"]
        if bad:
            raise RuntimeError(f"album {name}: {len(bad)} assets not added, e.g. {bad[0]}")
        self.added[name] += len(ids)

    def flush_all(self):
        with self.lock:
            for name in list(self.pending):
                self._flush(name)


# ---- import ---------------------------------------------------------------------

class Importer:
    def __init__(self, repo, api, albums, stage, total):
        self.repo, self.api, self.albums, self.stage, self.total = repo, api, albums, stage, total
        self.lock = threading.Lock()
        self.stat = collections.Counter()
        self.bytes_done = 0
        self.failed = []

    def process(self, it):
        err = None
        for attempt in range(1, ATTEMPTS + 1):
            try:
                return self._once(it)
            except Exception as e:  # noqa: BLE001 - anything: retry, then report
                err = e
                log(f"retry {attempt}/{ATTEMPTS} {it['path']}: {type(e).__name__}: {str(e)[:150]}")
                time.sleep(min(120, 5 * 2 ** attempt))
        with self.lock:
            self.failed.append((it["path"], f"{type(err).__name__}: {str(err)[:200]}"))

    def _once(self, it):
        d = tempfile.mkdtemp(dir=self.stage)
        try:
            dest = os.path.join(d, it["name"])
            sha1 = self.repo.restore_file(it["node"], dest)
            chk = self.api.call("POST", "/assets/bulk-upload-check",
                                {"assets": [{"id": "x", "checksum": sha1}]})["results"][0]
            if chk["action"] == "reject":
                if chk.get("reason") != "duplicate":
                    raise RuntimeError(f"rejected: {chk}")
                asset_id, outcome = chk["assetId"], "duplicate"
            else:
                iso = datetime.datetime.fromtimestamp(it["node"]["mtime"], datetime.timezone.utc).isoformat()
                fields = {"fileCreatedAt": iso, "fileModifiedAt": iso, "isFavorite": "false"}
                if it["rejected"]:
                    fields["visibility"] = "archive"
                status, asset_id = self.api.upload(fields, sha1, dest, it["name"], it["sidecar"])
                outcome = "duplicate" if status == "duplicate" else "uploaded"
            if it["album"]:
                self.albums.add(it["album"], asset_id)
        finally:
            shutil.rmtree(d, ignore_errors=True)
        with self.lock:
            self.stat[outcome] += 1
            self.stat["done"] += 1
            self.bytes_done += it["node"]["size"]

    def progress(self, started):
        with self.lock:
            s = dict(self.stat)
            log(f"progress {s.get('done', 0)}/{self.total} (uploaded {s.get('uploaded', 0)}, "
                f"already present {s.get('duplicate', 0)}, failed {len(self.failed)}) "
                f"{gib(self.bytes_done)} in {int(time.time() - started)}s")


def set_queues(api, pause):
    for q in JOBS_PAUSE:
        try:
            api.call("PUT", f"/queues/{q}", {"isPaused": pause})
        except Exception as e:  # noqa: BLE001
            log(f"queue {q} {'pause' if pause else 'resume'} failed: {e}")


def start_missing(api):
    for q in JOBS_START:
        try:
            api.call("PUT", f"/jobs/{q}", {"command": "start", "force": False})
            log(f"started missing: {q}")
        except Exception as e:  # noqa: BLE001 - "already running" is fine
            log(f"start {q}: {str(e)[:120]}")


# ---- main -----------------------------------------------------------------------

def main():
    dry = os.environ.get("DRY_RUN", "") not in ("", "0", "false")
    stage = os.environ.get("STAGE_DIR", "/work/stage")
    os.makedirs(stage, exist_ok=True)
    workers = int(os.environ.get("WORKERS", "2"))
    url = os.environ.get("IMMICH_URL", "http://immich-server.immich.svc:2283/api")
    api = Immich(url, os.environ["IMMICH_API_KEY"]) if os.environ.get("IMMICH_API_KEY") else None

    log("opening backup")
    repo = arq5.Repo(os.environ["ARQ_BUCKET"], os.environ["ARQ_PASSWORD"], [PICTURES, LIGHTROOM], stage)
    pics, lr = repo.head_commit(PICTURES), repo.head_commit(LIGHTROOM)
    log(f"Pictures backup {pics['created']:%Y-%m-%d}, Lightroom backup {lr['created']:%Y-%m-%d}")

    cat = os.environ.get("LRCAT_PATH")
    if not cat:
        cat = os.path.join(stage, "catalog.lrcat")
        log("restoring the Lightroom catalog")
        repo.restore_file(repo.find(lr, CATALOG_PATH), cat)
    log("walking Photos/")
    files = walk_photos(repo, pics)
    log(f"{len(files)} files below Photos/ (without {', '.join(sorted(EXCLUDED_DIRS))})")
    cat_items, missing, out_of_scope = read_catalog(cat, files.keys())
    if not os.environ.get("LRCAT_PATH") and os.path.exists(cat):
        os.remove(cat)
    plan = build_plan(files, cat_items)

    kinds = collections.Counter(i["kind"] for i in plan)
    rejected = sum(i["rejected"] for i in plan)
    albums = collections.Counter(i["album"] for i in plan if i["album"])
    total_bytes = sum(i["node"]["size"] for i in plan)
    log(f"plan: {len(plan)} files ({gib(total_bytes)}): catalogued {kinds['catalog']}, "
        f"leftovers {kinds['leftover']}, rejected (archive) {rejected}")
    log(f"catalog images not found in the backup: {len(missing)}; in Mobile Downloads (skipped): {out_of_scope}")
    for m in missing[:20]:
        log(f"  missing: {m}")
    log(f"albums: {len(albums)}; files without album: {sum(1 for i in plan if not i['album'])}")

    existing = {}
    if api:
        try:
            existing = Albums(api).existing
        except Exception as e:  # noqa: BLE001
            log(f"album list unavailable: {e}")
    log(f"albums to reuse: {sum(1 for a in albums if a in existing)}, to create: "
        f"{sum(1 for a in albums if a not in existing)}")
    for a, n in sorted(albums.items())[:15]:
        log(f"  album {a!r}: {n} files ({'exists' if a in existing else 'new'})")

    if dry:
        import xml.etree.ElementTree as ET
        bad = 0
        for i in plan:
            try:
                ET.fromstring(i["sidecar"])
            except ET.ParseError:
                bad += 1
                log(f"  invalid sidecar XML: {i['path']}")
        log(f"sidecars: {len(plan)} generated, {bad} invalid XML; with catalog keywords "
            f"{sum(i.get('has_kw', False) for i in plan)}, with caption {sum(i.get('has_cap', False) for i in plan)}, "
            f"with rating {sum(bool(i.get('rating')) for i in plan)}")
        skipped = sorted({i["path"].split("/")[2] for i in plan
                          if re.fullmatch(r"\d{4}", i["path"].split("/")[1]) and len(i["path"].split("/")) >= 4
                          and DATE_ONLY.fullmatch(i["path"].split("/")[2])})
        log(f"event folders skipped as pure dates: {len(skipped)}: {skipped[:25]}")
        tops = collections.Counter((i["path"].split("/")[1] if i["path"].count("/") >= 2 else "(loose)", i["kind"])
                                   for i in plan)
        log(f"files by top folder and kind: {sorted(tops.items())}")
        merged = collections.defaultdict(set)
        for i in plan:
            if i["album"]:
                merged[i["album"]].add(i["path"].split("/")[1])
        log(f"album names spanning several top folders: {[a for a, t in merged.items() if len(t) > 1]}")
        sd = os.environ.get("SAMPLE_DIR")
        picks = [next(i for i in plan if i["kind"] == "catalog"),
                 next(i for i in plan if i["kind"] == "leftover")]
        picks += [i for i in plan if i["rejected"]][:1]
        for i in picks:
            log(f"sample {i['kind']} {i['path']} album={i['album']!r} rejected={i['rejected']}\n"
                + i["sidecar"].decode()[-900:])
            if sd:
                os.makedirs(sd, exist_ok=True)
                open(os.path.join(sd, i["name"] + ".xmp"), "wb").write(i["sidecar"])
        log("dry run: no Immich writes")
        return 0

    albums_api = Albums(api)
    imp = Importer(repo, api, albums_api, stage, len(plan))
    started = time.time()
    set_queues(api, True)
    try:
        with concurrent.futures.ThreadPoolExecutor(workers) as ex:
            pending = {ex.submit(imp.process, i) for i in plan}
            while pending:
                _, pending = concurrent.futures.wait(pending, timeout=120)
                imp.progress(started)
        albums_api.flush_all()
    finally:
        try:
            albums_api.flush_all()
        except Exception as e:  # noqa: BLE001
            log(f"album flush failed: {e}")
            imp.failed.append(("(album flush)", str(e)))
        set_queues(api, False)
        start_missing(api)

    s = imp.stat
    log(f"summary: {len(plan)} files, uploaded {s['uploaded']}, already present {s['duplicate']}, "
        f"failed {len(imp.failed)}; {gib(imp.bytes_done)}; albums created {len(albums_api.created)}, "
        f"assets added to albums {sum(albums_api.added.values())}")
    if imp.failed:
        log("FAILED files:")
        for p, e in imp.failed:
            log(f"  {p}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
