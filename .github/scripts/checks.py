#!/usr/bin/env python3
"""Repo-specific validation. Runs without any secret: sops encrypts values but
leaves key names readable, so variable references can be checked from the
encrypted files directly."""
import re, subprocess, sys, json, pathlib

def tracked(*globs):
    out = subprocess.run(["git", "ls-files", *globs], capture_output=True, text=True).stdout
    return [p for p in out.splitlines() if p]

def yq(expr, path):
    r = subprocess.run(["yq", "-P", expr, path], capture_output=True, text=True)
    return [l.strip("- ").strip() for l in r.stdout.splitlines() if l.strip()]

# ${VAR}, but not $${VAR} which is escaped for a runtime shell
VAR = re.compile(r"(?<!\$)\$\{([A-Z_][A-Z0-9_]*)\}")

def check_vars() -> int:
    flux = set(yq('.stringData | keys | .[]', "infrastructure/vars/cluster-secrets.yaml"))
    talos = set(yq('keys | .[] | select(. != "sops")', "talos/talenv.sops.yaml"))
    bad = []
    for f in tracked("apps/*.yaml", "infrastructure/*.yaml", "fluxcd/*.yaml", "talos/*.yaml"):
        known = talos if f.startswith("talos/") else flux
        src = "talenv.sops.yaml" if f.startswith("talos/") else "cluster-secrets.yaml"
        for n, line in enumerate(pathlib.Path(f).read_text().splitlines(), 1):
            for v in VAR.findall(line):
                if v not in known:
                    bad.append(f"{f}:{n}: ${{{v}}} is not defined in {src}")
    print(f"  flux vars: {len(flux)} | talos vars: {len(talos)}")
    for b in bad: print("  FAIL", b)
    return 1 if bad else 0

def check_secrets() -> int:
    """Every Secret must have all data/stringData values sops-encrypted."""
    bad, n = [], 0
    for f in tracked("*.yaml"):
        text = pathlib.Path(f).read_text()
        if "kind: Secret" not in text:
            continue
        r = subprocess.run(["yq", "-o=json", '{"d": (.data // {}), "s": (.stringData // {})}', f],
                           capture_output=True, text=True)
        if r.returncode != 0:
            continue
        try:
            doc = json.loads(r.stdout)
        except Exception:
            continue
        n += 1
        for sect in ("d", "s"):
            for k, v in (doc.get(sect) or {}).items():
                if isinstance(v, str) and not v.startswith("ENC["):
                    bad.append(f"{f}: '{k}' is not encrypted")
    print(f"  Secret manifests checked: {n}")
    for b in bad: print("  FAIL", b)
    return 1 if bad else 0

DISCLOSURES = {
    "routable IPv6 prefix": re.compile(r"2a02:[0-9a-fA-F]{0,4}:"),
    "private IPv4 host":    re.compile(r"\b192\.168\.\d+\.\d+\b"),
    "MAC address":          re.compile(r"\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"),
    "personal email":       re.compile(r"\b[A-Za-z0-9._%+-]+@(?:me\.com|icloud\.com|gmail\.com)\b"),
}

def check_disclosures() -> int:
    """This repo is public. Network identifiers belong in sops, not in git."""
    bad = []
    for f in tracked("*.yaml", "*.yml", "*.md", "*.json"):
        for n, line in enumerate(pathlib.Path(f).read_text(errors="replace").splitlines(), 1):
            for label, rx in DISCLOSURES.items():
                m = rx.search(line)
                if m:
                    bad.append(f"{f}:{n}: {label} '{m.group(0)}' — move it into sops and reference a ${{VAR}}")
    for b in bad: print("  FAIL", b)
    if not bad: print("  no network identifiers committed")
    return 1 if bad else 0

if __name__ == "__main__":
    cmds = {"vars": check_vars, "secrets": check_secrets, "disclosures": check_disclosures}
    sys.exit(cmds[sys.argv[1]]())
