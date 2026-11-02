"""Read-only Arq 5 backup reader (S3 backend): decrypt, walk trees, restore files.

Format notes (verified against the arq_restore sources): encryptionv3.dat holds
the master keys (PBKDF2-SHA1, 200k rounds); every object is "ARQO" + HMAC +
IV + wrapped key + AES-CBC data; tree/commit/node records are version dependent;
file chunks are stored raw, gzip or LZ4 (4 byte big-endian size prefix).

Only the pack indexes are downloaded up front; pack contents are fetched with
ranged GETs, so no whole pack ever touches the disk.
"""
import concurrent.futures
import datetime
import gzip
import hashlib
import hmac
import os
import plistlib
import struct
import sys

import boto3
import lz4.block
from botocore.config import Config
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

COMPUTER = "EE3B1913-297F-4081-B9B3-9D697C598F41"
ENDPOINT = "https://s3.us-east-1.wasabisys.com"
REGION = "us-east-1"


def aes_cbc_decrypt(key, iv, ct):
    d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    pt = d.update(ct) + d.finalize()
    pad = pt[-1]
    if not 1 <= pad <= 16 or pt[-pad:] != bytes([pad]) * pad:
        raise ValueError("bad padding")
    return pt[:-pad]


def master_keys(raw, password):
    assert raw[:12] == b"ENCRYPTIONV2", raw[:12]
    salt, mac, iv, enc = raw[12:20], raw[20:52], raw[52:68], raw[68:]
    dk = hashlib.pbkdf2_hmac("sha1", password.encode(), salt, 200000, 64)
    if not hmac.compare_digest(hmac.new(dk[32:], iv + enc, hashlib.sha256).digest(), mac):
        sys.exit("wrong password (HMAC mismatch on encryptionv3.dat)")
    keys = aes_cbc_decrypt(dk[:32], iv, enc)
    return keys[:32], keys[32:64], keys[64:96]


class Repo:
    def __init__(self, bucket, password, folders, workdir):
        """folders: backup folder UUIDs whose pack indexes are needed."""
        self.bucket = bucket
        self.s3 = boto3.client(
            "s3", endpoint_url=ENDPOINT, region_name=REGION,
            config=Config(retries={"max_attempts": 10, "mode": "standard"}, max_pool_connections=32))
        self.packidx = {}  # sha1 -> (pack key, offset, length)
        self.k1, self.k2, self.k3 = master_keys(self._get(f"{COMPUTER}/encryptionv3.dat"), password)
        self._load_indexes(folders, workdir)

    # ---- S3 ----------------------------------------------------------------
    def _get(self, key, rng=None):
        kw = {"Range": rng} if rng else {}
        return self.s3.get_object(Bucket=self.bucket, Key=key, **kw)["Body"].read()

    def _load_indexes(self, folders, workdir):
        keys = []
        pag = self.s3.get_paginator("list_objects_v2")
        for f in folders:
            for kind in ("trees", "blobs"):
                prefix = f"{COMPUTER}/packsets/{f}-{kind}/"
                for page in pag.paginate(Bucket=self.bucket, Prefix=prefix):
                    keys += [o["Key"] for o in page.get("Contents", []) if o["Key"].endswith(".index")]
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            for key, data in zip(keys, ex.map(self._get, keys)):
                self._parse_index(key[:-6] + ".pack", data)
        print(f"loaded {len(keys)} pack indexes, {len(self.packidx)} objects", flush=True)

    def _parse_index(self, pack, d):
        assert d[:4] == b"\xfft\x4fc" and struct.unpack(">I", d[4:8])[0] == 2
        count = struct.unpack(">I", d[8 + 255 * 4:8 + 256 * 4])[0]
        p = 8 + 256 * 4
        for _ in range(count):
            off, ln = struct.unpack(">QQ", d[p:p + 16])
            self.packidx[d[p + 16:p + 36].hex()] = (pack, off, ln)
            p += 40

    def bucket_config(self, folder):
        b = self._get(f"{COMPUTER}/buckets/{folder}")
        assert b[:9] == b"encrypted"
        return plistlib.loads(self.decrypt(b[9:]).strip(), fmt=plistlib.FMT_XML)

    def head_commit(self, folder):
        head = self._get(f"{COMPUTER}/bucketdata/{folder}/refs/heads/master").decode().strip().rstrip("Y")
        return parse_commit(self.get(head))

    # ---- objects -----------------------------------------------------------
    def decrypt(self, blob):
        assert blob[:4] == b"ARQO", blob[:4]
        mac, miv, ekey, ct = blob[4:36], blob[36:52], blob[52:116], blob[116:]
        if not hmac.compare_digest(hmac.new(self.k2, miv + ekey + ct, hashlib.sha256).digest(), mac):
            raise ValueError("object HMAC mismatch")
        ivkey = aes_cbc_decrypt(self.k1, miv, ekey)
        return aes_cbc_decrypt(ivkey[16:48], ivkey[:16], ct)

    def _read_pack_entry(self, pack, off, ln):
        buf = self._get(pack, f"bytes={off}-{off + ln + 4096 - 1}")
        # the offset may point at the entry header (mimetype/name/len) or at the data
        if buf[:4] == b"ARQO":
            return buf[:ln] if len(buf) >= ln else self._get(pack, f"bytes={off}-{off + ln - 1}")
        p = 0
        for _ in range(2):
            if buf[p] == 1:
                n = struct.unpack(">Q", buf[p + 1:p + 9])[0]
                p += 9 + n
            else:
                p += 1
        n = struct.unpack(">Q", buf[p:p + 8])[0]
        p += 8
        if len(buf) < p + n:
            return self._get(pack, f"bytes={off + p}-{off + p + n - 1}")
        return buf[p:p + n]

    def raw(self, sha):
        if sha in self.packidx:
            return self._read_pack_entry(*self.packidx[sha])
        return self._get(f"{COMPUTER}/objects/{sha}")

    def get(self, sha, ctype=0):
        return decompress(self.decrypt(self.raw(sha)), ctype)

    # ---- tree access -------------------------------------------------------
    def tree(self, sha, ctype):
        return parse_tree(self.get(sha, ctype))[0]

    def find(self, commit, path):
        """Node of a path ("a/b/c") in a commit; raises KeyError if absent."""
        sha, ctype = commit["tree"], commit["ctype"]
        parts = path.split("/")
        for i, name in enumerate(parts):
            n = self.tree(sha, ctype)[name]
            if i == len(parts) - 1:
                return n
            sha, ctype = n["keys"][0], n["ctype"]

    def iter_files(self, node, prefix):
        """Yield (path, node) for every file below a tree node."""
        for name, n in sorted(self.tree(node["keys"][0], node["ctype"]).items()):
            if n["is_tree"]:
                yield from self.iter_files(n, f"{prefix}/{name}")
            else:
                yield f"{prefix}/{name}", n

    def restore_file(self, node, dest):
        """Write a file node to dest; returns its SHA1 hex digest."""
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        h, written = hashlib.sha1(), 0
        with open(dest, "wb") as out:
            for k in node["keys"]:
                chunk = self.get(k, node["ctype"])
                out.write(chunk)
                h.update(chunk)
                written += len(chunk)
        if written != node["size"]:
            raise ValueError(f"size mismatch on {dest}: wrote {written}, expected {node['size']}")
        return h.hexdigest()


def decompress(data, ctype):
    if ctype == 0:
        return data
    if ctype == 1:
        return gzip.decompress(data)
    if ctype == 2:
        if not data:
            return b""
        size = struct.unpack(">i", data[:4])[0]
        return lz4.block.decompress(data[4:], uncompressed_size=size)
    raise ValueError(f"compression type {ctype}")


class R:
    def __init__(self, b):
        self.b, self.p = b, 0

    def take(self, n):
        v = self.b[self.p:self.p + n]
        self.p += n
        return v

    def bool(self): return self.take(1)[0] != 0
    def i32(self): return struct.unpack(">i", self.take(4))[0]
    def u32(self): return struct.unpack(">I", self.take(4))[0]
    def i64(self): return struct.unpack(">q", self.take(8))[0]
    def u64(self): return struct.unpack(">Q", self.take(8))[0]

    def str(self):
        if not self.bool():
            return None
        return self.take(self.u64()).decode("utf-8", "surrogateescape")

    def date(self):
        if not self.bool():
            return None
        return datetime.datetime.fromtimestamp(self.u64() / 1000, datetime.timezone.utc)

    def blobkey(self, v):
        sha = self.str()
        if v >= 14: self.bool()
        if v >= 17:
            self.u32(); self.str(); self.u64(); self.date()
        return sha


def parse_commit(b):
    r = R(b)
    hdr = r.take(10).decode()
    assert hdr.startswith("CommitV"), hdr
    v = int(hdr[7:])
    r.str(); r.str()
    parents = []
    for _ in range(r.u64()):
        parents.append(r.str())
        if v >= 4: r.bool()
    tree = r.str()
    if v >= 4: r.bool()
    ctype = 0
    if 8 <= v <= 9:
        ctype = 1 if r.bool() else 0
    elif v >= 10:
        ctype = r.i32()
    location = r.str()
    if v < 8:
        r.str()
        if v >= 4: r.bool()
    created = r.date()
    failed = []
    if v >= 3:
        for _ in range(r.u64()):
            failed.append((r.str(), r.str()))
    complete = None
    if v >= 8: r.bool()
    if v >= 9: complete = r.bool()
    return dict(version=v, parents=parents, tree=tree, ctype=ctype, location=location,
                created=created, failed=failed, complete=complete)


def parse_node(r, v):
    is_tree = r.bool()
    if v >= 18: r.bool()
    dctype = 0
    if 12 <= v <= 18:
        dctype = 1 if r.bool() else 0
        r.bool(); r.bool()
    if v >= 19:
        dctype = r.i32(); r.i32(); r.i32()
    keys = [r.blobkey(v) for _ in range(r.i32())]
    size = r.u64()
    if v < 18:
        r.blobkey(v); r.blobkey(v)
    r.blobkey(v); r.u64(); r.blobkey(v)
    r.i32(); r.i32(); mode = r.i32()
    mtime = r.i64(); r.i64(); r.i64(); r.i32(); r.i32()
    r.str(); r.str(); r.bool()
    r.i32(); r.i32(); r.u32(); r.i32(); r.i64(); r.i64(); r.i64(); r.i64(); r.i64(); r.u32()
    return dict(is_tree=is_tree, ctype=dctype, keys=keys, size=size, mode=mode, mtime=mtime)


def parse_tree(b):
    r = R(b)
    hdr = r.take(8).decode()
    assert hdr.startswith("TreeV"), hdr
    v = int(hdr[5:])
    if 12 <= v <= 18: r.bool(); r.bool()
    if v >= 19: r.i32(); r.i32()
    r.blobkey(v); r.u64(); r.blobkey(v)
    r.i32(); r.i32(); r.i32(); r.i64(); r.i64(); r.i64(); r.i32(); r.i32()
    r.i32(); r.i32(); r.u32(); r.i32(); r.i64(); r.i64(); r.i64(); r.u32()
    if 11 <= v <= 16: r.u64()
    if v >= 15: r.i64(); r.i64()
    missing = []
    if v >= 18:
        for _ in range(r.u32()):
            missing.append(r.str())
            parse_node(r, v)
    nodes = {}
    for _ in range(r.u32()):
        name = r.str()
        nodes[name] = parse_node(r, v)
    return nodes, missing
