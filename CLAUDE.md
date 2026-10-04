# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GitOps homelab: Talos Linux on four Turing RK1 (arm64) nodes plus an x86 `nas`
node, with Flux CD reconciling everything in `apps/` and `infrastructure/` into
the cluster. **The repo is public** (`github.com/jigfox/homelab`) —
see "Public-repo invariants" below.

Nothing is applied by hand. A change takes effect by being committed and pushed;
Flux pulls `main` every minute.

## Layout

| Path | Role |
| --- | --- |
| `fluxcd/homelab/` | The dependency graph. One `kustomize.toolkit` Kustomization per unit, listed in `kustomization.yaml`. This is where you declare *when* something reconciles, not *what* it contains. |
| `fluxcd/homelab/flux-system/` | Flux's own components, self-managed. Do not hand-edit; excluded from Renovate. |
| `infrastructure/sources/` | `HelmRepository` objects. Every `HelmRelease` must have its repo defined here. |
| `infrastructure/base/<x>/` | The component itself (HelmRelease or plain manifests). |
| `infrastructure/configs/<x>-network/` | CRs that only exist once the component's CRDs are installed, hence a separate Kustomization that `dependsOn` the base one. |
| `infrastructure/vars/cluster-secrets.yaml` | The sops-encrypted `cluster-secrets` Secret backing every `${VAR}`. Its Kustomization is named **`infrastructure`**. |
| `apps/<name>/` | One directory per app, each with its own `namespace.yaml` and `kustomization.yaml`. |
| `talos/` | talhelper inputs; node configs are generated into `clusterconfig/` (gitignored, along with `talosconfig`/`kubeconfig`). |

Untracked top-level directories (`cnpg/`, `redis/`, `igpu/`, `paperless/`, …)
plus `Taskfile.yml`, `package.json` and `index*.ts` are the **legacy Pulumi
stacks** this repo is migrating away from. Git history shows the per-app
"migrate X from pulumi to flux" commits. New work goes in `apps/` as Flux
manifests; don't extend the Pulumi side.

## Adding an app

1. `apps/<name>/` with `namespace.yaml`, a `kustomization.yaml` listing the
   resources explicitly, and the workload.
2. `fluxcd/homelab/apps-<name>.yaml` — a Kustomization with `path: ./apps/<name>`,
   `prune: true`, `dependsOn: [infrastructure]` (plus `infra-longhorn` if it has
   a PVC, `infra-sources` if it has a HelmRelease).
3. Add that file to `fluxcd/homelab/kustomization.yaml`.

Expose it over HTTP by attaching an `HTTPRoute` to the shared Gateway
(`name: cilium`, `namespace: gateway-default`, `sectionName: https`) with
`hostnames: [<name>.${GATEWAY_DOMAIN}]`. The Gateway holds a wildcard cert and
external-dns publishes `*.${GATEWAY_DOMAIN}`, so no per-app DNS or TLS is needed.

## Variables and secrets

Two separate mechanisms, often confused:

- **`${VAR}` substitution** — resolved by Flux `postBuild.substituteFrom` against
  the `cluster-secrets` Secret. A Kustomization only gets these if it declares
  `postBuild.substituteFrom: [{kind: Secret, name: cluster-secrets}]` **and**
  `dependsOn: [infrastructure]`. A new variable must be added to
  `infrastructure/vars/cluster-secrets.yaml` or CI fails. Use `$${VAR}` to escape
  a variable meant for a runtime shell (e.g. the multus setup script).
- **sops** — in-cluster decryption via `decryption.provider: sops` +
  `secretRef: sops-age`. Root `.sops.yaml` encrypts only matching keys
  (`data`, `stringData`, `peerASN`, `cidr`, `email`, `*hostname`, `dnsNames`) so
  diffs stay readable; `talos/.sops.yaml` encrypts whole files. Any Kustomization
  whose path contains a Secret needs the `decryption` block.

Edit encrypted files with `sops <file>`, never by hand.

## Public-repo invariants (CI enforces all three)

`.github/scripts/checks.py` runs on every PR:

- `vars` — every `${VAR}` in `apps/`, `infrastructure/`, `fluxcd/` exists in
  `cluster-secrets.yaml`; in `talos/`, in `talenv.sops.yaml`.
- `secrets` — every `data`/`stringData` value in any `kind: Secret` starts with `ENC[`.
- `disclosures` — **no `192.168.x.x`, no `2a02:…` prefix, no MAC address, no
  personal email may appear in any tracked file.** Put the value in sops and
  reference `${VAR}` instead. This guards a history scrub; do not weaken it.

## Commands

Tooling is pinned in `mise.toml`; `mise install` then work inside the directory.
`TALOSCONFIG`/`KUBECONFIG` are exported automatically to `talos/clusterconfig/`.

Reproduce CI locally (nothing here needs a sops key):

```sh
.github/scripts/render.sh /tmp/rendered   # kustomize-build every kustomization with placeholders
.github/scripts/helm-template.sh          # helm template every HelmRelease at its pinned version
python3 .github/scripts/checks.py vars | secrets | disclosures
gitleaks git --no-banner --redact --verbose
```

Flux:

```sh
flux get kustomizations -A
flux reconcile kustomization <name> --with-source   # don't wait for the interval
flux logs --kind=Kustomization --name=<name>
```

Talos (from `talos/`):

```sh
talhelper genconfig                 # -> clusterconfig/
mise run generate-secret            # regenerate talsecret.sops.yaml
mise run download-rk1               # resolve the image factory schematic id
mise run scale-down / scale-up      # park workloads around a node upgrade, via replica_backup.txt
```

## Conventions

- **Commits**: conform (`.conform.yaml`) allows the conventional type **`feat`
  only**, header ≤89 chars. Renovate is configured to match. lefthook runs
  gitleaks pre-commit and conform on commit-msg.
- **Renovate** automerges patch/digest only; `cilium`, `longhorn`, `cert-manager`
  and `kube-prometheus-stack` are always reviewed. `talos/**` and the generated
  flux components are ignored. `hub.f9k.dev` images are disabled (LAN-only).
- `prune: true` everywhere except `infra-cilium` — deleting the CNI's manifests
  must not delete the CNI.

## Cluster facts worth knowing before editing

- **Cilium** does everything network: kube-proxy is disabled in Talos
  (`kubeProxyReplacement: true`), plus BGP to the UniFi router, L2 announcements,
  and the Gateway API implementation. `gateway-api` CRDs install *before* Cilium.
- **Longhorn** (`storageClassName: longhorn`) on a dedicated `longhorn-data` user
  volume per node, default 2 replicas.
- **SQLite apps run a litestream sidecar** replicating to Wasabi S3 — the pattern
  to copy is `apps/mealie` or `apps/sso`. Pods carry `litestream: "true"` so the
  shared PodMonitor scrapes them.
- **Kyverno** mutates every Pod to mount the internal CA bundle, so manifests
  don't do CA plumbing themselves.
- **Authelia + lldap** (`apps/sso`) provide OIDC; apps authenticate against
  `https://sso.${GATEWAY_DOMAIN}` with password login disabled.
- **Multus** gives Home Assistant a second interface on the LAN VLAN; its
  Kustomization depends on `infra-multus-config`.
