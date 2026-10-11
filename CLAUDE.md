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
| `talos/` | topf inputs: `topf.yaml` (nodes + data), patches in `all/`, `control-plane/`, `worker/`, and the schematics. `clusterconfig/` holds the gitignored `talosconfig`/`kubeconfig`. |

Untracked top-level directories (`cnpg/`, `redis/`, `igpu/`, `paperless/`, …)
plus `Taskfile.yml`, `package.json` and `index*.ts` are **obsolete leftovers**
of a Pulumi setup that no longer exists; ignore them. Everything is managed
through Flux. Cluster objects that look Pulumi-made (hash-suffixed names,
`pulumi.com/autonamed`) are unmanaged leftovers: adopt them into git (see
"Adopting live objects") or delete them, nothing else owns them.

## Adopting live objects

To bring an object that already exists in the cluster under Flux, write a
manifest with the **same name and namespace** as the live one. kustomize-controller
applies server-side with force, so it takes the object over instead of creating a
new one. Immutable fields (a StatefulSet's `selector`, `serviceName` and
`volumeClaimTemplates`, a Service's `clusterIP`) must stay byte-for-byte as live,
otherwise the apply fails or recreates the workload. Compare against
`kubectl get -o yaml` before merging, and dry-run it with
`kubectl diff --server-side --field-manager=kustomize-controller`.
Server-side apply never removes fields owned by another field manager: turning a
live env `value` into a `valueFrom` (e.g. moving a secret into sops) leaves both
and the apply is rejected. Migrate such fields first (create the Secret, then a
JSON patch that removes `value` and adds `valueFrom`), then merge.

## Adding an app

1. `apps/<name>/` with `namespace.yaml`, a `kustomization.yaml` listing the
   resources explicitly, and the workload.
2. `fluxcd/homelab/apps-<name>.yaml` — a Kustomization with `path: ./apps/<name>`,
   `prune: true`, `dependsOn: [infrastructure]` (plus `infra-longhorn` if it has
   a PVC, `infra-sources` if it has a HelmRelease).
3. Add that file to `fluxcd/homelab/kustomization.yaml`.

Every container and initContainer (init containers included) needs
`resources.requests.cpu`, `resources.requests.memory` and
`resources.limits.memory`. **No CPU limits** — they only throttle. Goldilocks at
`goldilocks.${GATEWAY_DOMAIN}` (SSO login) shows VPA recommendations to start
from; sidecars like litestream need their own block too. The Kyverno policy
`require-resources` reports violations (see "Cluster facts").

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
  diffs stay readable; `talos/.sops.yaml` encrypts only `ip`, `clusterEndpoint` and `data` in `topf.yaml` and the whole secrets bundle. Any Kustomization
  whose path contains a Secret needs the `decryption` block.

Edit encrypted files with `sops <file>`, never by hand.

## Public-repo invariants (CI and the lefthook pre-push hook enforce these)

`.github/scripts/checks.py` runs on every PR and before every push:

- `vars` — every `${VAR}` in `apps/`, `infrastructure/`, `fluxcd/` exists in
  `cluster-secrets.yaml`; in `talos/`, every `{{ .Data.X }}` / `{{ .Node.Data.X }}` in a `.tpl` patch exists in `topf.yaml`, and no `${VAR}` is left.
- `secrets` — every `data`/`stringData` value in any `kind: Secret` starts with `ENC[`.
- `disclosures` — **no `192.168.x.x`, no `2a02:…` prefix, no MAC address, no
  personal email, and not the cluster's own domain (also as `dc=…,dc=…`) may
  appear in any tracked file.** Put the value in sops and reference `${VAR}`
  instead — the domain is `${GATEWAY_DOMAIN}`, the LDAP base DN
  `${LDAP_BASE_DN}`. The domain is checked by sha256 in `PRIVATE_DOMAINS` so
  the script doesn't disclose it; never write it in plain text, not even in
  comments. This guards a history scrub; do not weaken it.
- `versions` — `talos/topf.yaml` is the **single source** for the cluster's
  `talosVersion` and `kubernetesVersion` (both unencrypted). kubeconform and
  `helm-template.sh` read it; the `kubectl` pin may be at most one minor away,
  the `talosctl` pin must match the Talos minor. Bump versions there, not in CI.

## Commands

Tooling is pinned in `mise.toml` (repo-wide) and `talos/mise.toml` (Talos-only:
talosctl, tpi, cilium-cli); `mise install` in both, then work inside the
directory. It is a mise monorepo, so Talos tasks run from the root as
`mise //talos:<task>`. `KUBECONFIG` is exported at the root and `TALOSCONFIG`
in `talos/`, both pointing into `talos/clusterconfig/`.
`mise run install-cilium` bootstraps Cilium on a freshly reset cluster, using
the chart version from `infrastructure/base/cilium/release.yaml`.

Reproduce CI locally (nothing here needs a sops key):

```sh
.github/scripts/render.sh /tmp/rendered   # kustomize-build every kustomization with placeholders
.github/scripts/helm-template.sh          # helm template every HelmRelease at its pinned version
python3 .github/scripts/checks.py vars | secrets | disclosures | versions
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
topf render --online -o /tmp/out    # per-node machine configs, secrets included, keep out of the repo
topf apply --dry-run                # diff against the live nodes, exit 2 if anything differs
topf apply --nodes-filter '^node2$' --mode=no-reboot
topf talosconfig > clusterconfig/talosconfig
talosctl -n <ip> get mc v1alpha1 -o jsonpath='{.spec}' > backup/<host>.yaml  # gitignored; restore via apply-config
mise //talos:schematic-ids          # image factory schematic ids resolved from the schematic-*.yaml files
mise //talos:upgrade [--dry-run]    # bump talosVersion in topf.yaml first; node by node, waits for Longhorn health, then runs the descheduler
mise //talos:upgrade-k8s [--dry-run] [--sync-manifests]  # bump kubernetesVersion in topf.yaml first; --sync-manifests after changing extraManifests URLs
mise //talos:longhorn-down [--dry-run] / longhorn-up  # park/restore manually, state in backup/longhorn-workloads.json
```

Upgrade Talos with `mise //talos:upgrade`, not a bare `topf upgrade`. It goes
node by node (workers, control planes, nas last) without scaling anything down,
and only moves on once every attached Longhorn volume is `healthy` with no
replica rebuilding. `replica-auto-balance` is set to `disabled` for the
duration (original value in `talos/backup/upgrade-state.json`) and restored
after the last node; if a run fails it stays disabled and re-running resumes
with the remaining nodes. At the end it runs the descheduler once, because
Kubernetes never moves running pods back onto the node upgraded last.
`longhorn-down` (suspends Flux, pauses the Prometheus/Alertmanager CRs, scales
every Longhorn workload to zero) and `longhorn-up` are for manual maintenance
only; the upgrade no longer calls them.

## Conventions

- **Commits**: conform (`.conform.yaml`) allows only the conventional types
  **`feat` and `chore`**, header ≤89 chars, description ≤72 chars. Renovate
  always uses `feat` (its default `fix(deps)` would be rejected). lefthook runs
  gitleaks pre-commit and conform on commit-msg.
- **Renovate** automerges patch/digest only; `cilium`, `longhorn`, `cert-manager`
  and `kube-prometheus-stack` are always reviewed, as are the `talosctl` and
  `kubectl` mise pins (they must match the cluster). The generated flux
  components are ignored. `hub.${GATEWAY_DOMAIN}` images are disabled (LAN-only).
- `prune: true` everywhere except `infra-cilium` — deleting the CNI's manifests
  must not delete the CNI.

## Cluster facts worth knowing before editing

- **Cilium** does everything network: kube-proxy is disabled in Talos
  (`kubeProxyReplacement: true`), plus BGP to the UniFi router, L2 announcements,
  and the Gateway API implementation. `gateway-api` CRDs install *before* Cilium.
- **Longhorn** (`storageClassName: longhorn`) on a dedicated `longhorn-data` user
  volume per node: 3 replicas, data locality `disabled`, node drain policy
  `block-for-eviction-if-contains-last-replica`, `replica-auto-balance:
  best-effort` (off only during Talos upgrades). These live in
  `infrastructure/base/longhorn/release.yaml`, not the UI; they apply to the
  StorageClass and the settings, but **not to existing volumes**, which must be
  patched once with `kubectl -n longhorn-system patch volumes.longhorn.io <v>
  --type merge -p '{"spec":{"numberOfReplicas":3,"dataLocality":"disabled"}}'`
  (needs about 230 GB more scheduled; wait until all volumes are `healthy`).
  If Helm doesn't override a hand-set setting, patch `settings.longhorn.io`
  once; a stale StorageClass can be deleted and Longhorn recreates it
  (existing PVCs are unaffected). Talos workload isolation is kept **off**
  (`talos/all/05-security.yaml`) because it is untested with Longhorn's iSCSI;
  don't drop that patch as part of an unrelated change. The backup target
  (Wasabi, `defaultBackupStore` plus the sops Secret `backup-access-keys-wasabi`)
  is in git too, so `infra-longhorn` needs `infrastructure` for substitution.
  The UI at `longhorn.${GATEWAY_DOMAIN}` is behind oauth2-proxy and the Authelia
  `longhorn` client; its HTTPRoute is still called `registry-route` because it
  was adopted under that name.
- **Descheduler** (`kube-system`, CronJob `descheduler`, nightly at 03:00 and
  once at the end of `mise //talos:upgrade`) evens out CPU/memory requests with
  `LowNodeUtilization` (thresholds 20, targets 35, `nodeFit: true`), skipping
  kube-system, longhorn-system, flux-system, cert-manager and kyverno.
- **SQLite apps run a litestream sidecar** replicating to Wasabi S3 — the pattern
  to copy is `apps/mealie` or `apps/sso`. Pods carry `litestream: "true"` so the
  shared PodMonitor scrapes them.
- **Kyverno** mutates every Pod to mount the internal CA bundle, so manifests
  don't do CA plumbing themselves.
- **`require-resources`** (Kyverno ClusterPolicy, `infrastructure/configs/kyverno`)
  flags Pods whose containers lack CPU/memory requests or a memory limit. It is
  in `Audit` mode for now; check `kubectl get policyreport -A`. Excluded
  namespaces, because their pods aren't ours to template: `kube-system` (Talos
  static pods, metrics-server), `longhorn-system` (instance-manager and CSI pods
  created by the operator) and the unmanaged leftover namespaces `cnpg-system`,
  `nextcloud`, `intel-igpu`, `redis-system`. Remove those from the exclusion
  list when they are adopted into git or deleted.
- **Goldilocks** (`infra-goldilocks`) runs on a recommender-only VPA
  (`infra-vpa`: no updater, no admission controller, so pods are never changed).
  The dashboard sits behind oauth2-proxy and the Authelia `goldilocks` client.
- **Authelia + lldap** (`apps/sso`) provide OIDC; apps authenticate against
  `https://sso.${GATEWAY_DOMAIN}` with password login disabled.
- **Multus** gives Home Assistant a second interface on the LAN VLAN; its
  Kustomization depends on `infra-multus-config`.
