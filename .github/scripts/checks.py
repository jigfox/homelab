#!/usr/bin/env python3
"""Repo-specific validation. Runs without any secret: sops encrypts values but
leaves key names readable, so variable references can be checked from the
encrypted files directly."""
import re, subprocess, sys, json, pathlib, hashlib

def tracked(*globs):
    out = subprocess.run(["git", "ls-files", *globs], capture_output=True, text=True).stdout
    return [p for p in out.splitlines() if p]

def yq(expr, path):
    r = subprocess.run(["yq", "-P", expr, path], capture_output=True, text=True)
    return [l.strip("- ").strip() for l in r.stdout.splitlines() if l.strip()]

# ${VAR}, but not $${VAR} which is escaped for a runtime shell
VAR = re.compile(r"(?<!\$)\$\{([A-Z_][A-Z0-9_]*)\}")

# {{ .Data.X }} / {{ .Node.Data.X }} in topf patch templates
TPL = re.compile(r"\{\{-?\s*\.(Node\.)?Data\.([A-Za-z_][A-Za-z0-9_]*)")

def check_vars() -> int:
    flux = set(yq('.stringData | keys | .[]', "infrastructure/vars/cluster-secrets.yaml"))
    data = set(yq('.data | keys | .[]', "talos/topf.yaml"))
    node_data = set(yq('.nodes[].data | keys | .[]', "talos/topf.yaml"))
    bad = []
    for f in tracked("apps/*.yaml", "infrastructure/*.yaml", "fluxcd/*.yaml", "talos/*.yaml", "talos/*.tpl"):
        for n, line in enumerate(pathlib.Path(f).read_text().splitlines(), 1):
            if f.startswith("talos/"):
                for node, key in TPL.findall(line):
                    if key not in (node_data if node else data):
                        bad.append(f"{f}:{n}: {{{{ .{node}Data.{key} }}}} is not defined in topf.yaml")
                for v in VAR.findall(line):
                    bad.append(f"{f}:{n}: ${{{v}}} is not substituted in talos/, use topf data templates")
            else:
                for v in VAR.findall(line):
                    if v not in flux:
                        bad.append(f"{f}:{n}: ${{{v}}} is not defined in cluster-secrets.yaml")
    print(f"  flux vars: {len(flux)} | topf data: {len(data)} | topf node data: {len(node_data)}")
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

# sha256 of private domains, hashed so this public script doesn't disclose them;
# matched against the last two labels of every hostname and against dc=x,dc=y
PRIVATE_DOMAINS = {"b2dcd460d9f4afc9739b5ea6fef8022bb78a25153da91b4bd5e76b7aed1ca0e9"}
HOSTNAME = re.compile(r"\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b", re.I)
LDAP_DN = re.compile(r"\bdc=([a-z0-9-]+),\s*dc=([a-z0-9-]+)\b", re.I)

def has_private_domain(line: str) -> bool:
    candidates = [".".join(m.group(0).split(".")[-2:]) for m in HOSTNAME.finditer(line)]
    candidates += [f"{a}.{b}" for a, b in LDAP_DN.findall(line)]
    return any(hashlib.sha256(c.lower().encode()).hexdigest() in PRIVATE_DOMAINS for c in candidates)

def check_disclosures() -> int:
    """This repo is public. Network identifiers belong in sops, not in git."""
    bad = []
    for f in tracked("*.yaml", "*.yml", "*.md", "*.json", "*.tpl"):
        for n, line in enumerate(pathlib.Path(f).read_text(errors="replace").splitlines(), 1):
            for label, rx in DISCLOSURES.items():
                m = rx.search(line)
                if m:
                    bad.append(f"{f}:{n}: {label} '{m.group(0)}' — move it into sops and reference a ${{VAR}}")
            # the match itself is not printed: CI logs are public too
            if has_private_domain(line):
                bad.append(f"{f}:{n}: private domain — use ${{GATEWAY_DOMAIN}} or another sops value")
    for b in bad: print("  FAIL", b)
    if not bad: print("  no network identifiers committed")
    return 1 if bad else 0

def minor(v: str) -> tuple:
    return tuple(int(x) for x in v.lstrip("v").split(".")[:2])

def check_versions() -> int:
    """talos/topf.yaml is the single source for the cluster's Talos and
    Kubernetes versions; the pinned clients must stay compatible with it."""
    import tomllib
    kube = yq(".kubernetesVersion", "talos/topf.yaml")[0]
    talos = yq(".talosVersion", "talos/topf.yaml")[0]
    kubectl = tomllib.loads(pathlib.Path("mise.toml").read_text())["tools"]["kubectl"]
    talosctl = tomllib.loads(pathlib.Path("talos/mise.toml").read_text())["tools"]["talosctl"]
    bad = []
    # kubectl supports one minor version of skew in either direction
    if minor(kubectl)[0] != minor(kube)[0] or abs(minor(kubectl)[1] - minor(kube)[1]) > 1:
        bad.append(f"kubectl {kubectl} (mise.toml) is more than one minor away from Kubernetes {kube}")
    if minor(talosctl) != minor(talos):
        bad.append(f"talosctl {talosctl} (talos/mise.toml) does not match Talos {talos}")
    print(f"  kubernetes {kube} / kubectl {kubectl} | talos {talos} / talosctl {talosctl}")
    for b in bad: print("  FAIL", b)
    return 1 if bad else 0

if __name__ == "__main__":
    cmds = {"vars": check_vars, "secrets": check_secrets, "disclosures": check_disclosures,
            "versions": check_versions}
    sys.exit(cmds[sys.argv[1]]())
