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
| `devices/` | sops-encrypted credentials of devices outside the cluster (e.g. `tasmota.yaml`). Not in any Kustomization, never applied. |
| `unifi/` | OpenTofu root module for the UniFi Dream Machine, reconciled by tofu-controller (see "UniFi as code"). |
| `infrastructure/configs/technitium/` | The `TechnitiumServer`s (block list URLs, app settings); the allowed/blocked domains are in the private repo `jigfox/homelab-dns` (see "technitium operator"). |
| `infrastructure/configs/lldap-groups/` | The `LLDAPGroup`s that Authelia's policies refer to (see "lldap operator"); the users are in the private repo `jigfox/homelab-users`. |
| `talos/` | topf inputs: `topf.yaml` (nodes + data), patches in `all/`, `control-plane/`, `worker/`, and the schematics. `clusterconfig/` holds the gitignored `talosconfig`/`kubeconfig`. |

Everything is managed through Flux; the former Pulumi setup is gone. Cluster objects that look Pulumi-made (hash-suffixed names,
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
`resources.limits.memory`. **No CPU limits** — they only throttle. KRR (`mise run krr`, or the
report at `krr.${GATEWAY_DOMAIN}`, SSO login) gives recommendations to start
from; sidecars like litestream need their own block too. The Kyverno policy
`require-resources` reports violations (see "Cluster facts").

Every app namespace has a `CiliumNetworkPolicy` `ingress`
(`networkpolicy.yaml`) that allows only its known callers; everything else
inbound is dropped, egress is open. Copy one (`apps/mealie` is the simple case)
and list: the Gateway (`fromEntities: [ingress]`) on the pod's UI port, the
`monitoring` namespace on metrics ports (litestream `9090`), the same
namespace if its pods talk to each other, and every other namespace that
calls a Service in it (e.g. `homeassistant` -> `smarthome:1883`). Ports are the
container ports, not the Service ports. The Gateway's ExternalAuth calls are
the exception: Envoy sends them from its node, so authelia also allows `host`
and `remote-node` on 9091. Multus/macvlan traffic and kubelet
probes are not affected. A caller you forgot shows up in
`hubble observe --verdict DROPPED --drop-reason-desc POLICY_DENIED`
(`kubectl -n kube-system port-forward svc/hubble-relay 4245:80` first).

Expose it over HTTP by attaching an `HTTPRoute` to the shared Gateway
(`name: cilium`, `namespace: gateway-default`, `sectionName: https`) with
`hostnames: [<name>.${GATEWAY_DOMAIN}]`. The Gateway holds a wildcard cert and
external-dns publishes `*.${GATEWAY_DOMAIN}`, so no per-app DNS or TLS is needed.
The https listener only accepts routes from namespaces labelled
`homelab/gateway-routes: "true"`: put that label on the app's `namespace.yaml`,
otherwise the route stays `Accepted=False` (`NotAllowedByListeners`). Admin UIs
without their own SSO get the ExternalAuth filter to authelia (copy
`infrastructure/base/krr/http-route.yaml`), their domain in the authelia
`access_control` rule and, outside `sso`, their namespace in
`apps/sso/referencegrant-authz.yaml`.

To make an app reachable from the internet, see the public Gateway under
"Cluster facts": label its namespace `homelab/public-routes: "true"`, add a
second parentRef (`name: public`, `sectionName: https`) to its HTTPRoute and
append its hostname to the `external-dns.kubernetes.io/hostname` annotation of
`infrastructure/base/gateway/public.yaml` (comma separated). Anything public
must authenticate itself (OIDC); the ExternalAuth filter is not enough for an
internet-facing admin UI.

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

Edit encrypted files with `sops <file>`, never by hand. To review changes to
them decrypted, use `git sdiff` / `git sshow` / `git slog` (aliases set by the
mise enter hook, textconv via `.gitattributes` and `.mise/lib/sops-textconv`).
Plain `git diff` deliberately stays encrypted: a permanent textconv would make
gitleaks (which reads `git log -p`) scan plaintext and fail every commit.

The in-cluster key is the hand-made Secret `flux-system/sops-age`, not in git.
Re-encrypting to a new recipient breaks every sops Kustomization unless that
Secret gets the new key first; follow "Rotating the sops age key" in
`README.md`.

## Public-repo invariants (CI and the lefthook pre-push hook enforce these)

`.github/scripts/checks.py` runs on every PR and before every push:

- `vars` — every `${VAR}` in `apps/`, `infrastructure/`, `fluxcd/` exists in
  `cluster-secrets.yaml` and is not empty (Flux substitutes both with `""`);
  in `talos/`, every `{{ .Data.X }}` / `{{ .Node.Data.X }}` in a `.tpl` patch exists in `topf.yaml`, and no `${VAR}` is left.
  A `${VAR}` inside a sops-encrypted value (e.g. the restic credentials in the
  app Secrets) is only visible decrypted, so that part runs in the pre-push
  hook and is skipped in CI, which has no age key.
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
in `talos/`, both pointing into `talos/clusterconfig/`. Entering the repo runs
`mise //talos:clientconfigs`, which generates both offline from the secrets
bundle (sops key needed) when missing or expiring within 14 days (`--force`
regenerates them).
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
talosctl -n <ip> get mc v1alpha1 -o jsonpath='{.spec}' > backup/<host>.yaml  # gitignored; restore via apply-config
mise //talos:schematic-ids          # image factory schematic ids resolved from the schematic-*.yaml files
mise //talos:raid-create [--dry-run] <disk...>  # one-time: nas md RAID5 from by-id disks (wipes them); raid-add <disk> grows it, raid-status / raid-growfs
mise //talos:upgrade [--dry-run]    # bump talosVersion in topf.yaml first; node by node, waits for Longhorn health, then runs the descheduler
mise //talos:reboot [--dry-run] [--nodes-filter <regex>]  # reboot node by node with the upgrade's guards (drain, Longhorn/etcd healthy between nodes); refuses while topf apply --dry-run differs
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
`longhorn-down` (suspends Flux, pauses the VMSingle/VMAlertmanager CRs, scales
every Longhorn workload to zero) and `longhorn-up` are for manual maintenance
only; the upgrade no longer calls them.

## Conventions

- **Commits**: conform (`.conform.yaml`) allows only the conventional types
  **`feat` and `chore`**, header ≤89 chars, description ≤72 chars. Renovate
  always uses `feat` (its default `fix(deps)` would be rejected). lefthook runs
  gitleaks pre-commit and conform on commit-msg.
- **Renovate** automerges patch/digest only; `cilium`, `longhorn`, `cert-manager`,
  `victoria-metrics-k8s-stack`, `cloudnative-pg`, `plugin-barman-cloud` and the
  `cloudnative-vectorchord` Postgres image are always reviewed, as are the `talosctl` and
  `kubectl` mise pins (they must match the cluster). The generated flux
  components are ignored.
- `prune: true` everywhere except `infra-cilium` — deleting the CNI's manifests
  must not delete the CNI.

## Cluster facts worth knowing before editing

- **Cilium** does everything network: kube-proxy is disabled in Talos
  (`kubeProxyReplacement: true`), plus BGP to the UniFi router, L2 announcements,
  and the Gateway API implementation. `gateway-api` CRDs install *before* Cilium;
  they are vendored (`infrastructure/base/gateway-api/experimental-install.yaml`,
  version on the `# source:` line of its kustomization) so a GitHub outage can't
  block the CNI chain. Renovate bumps that line; re-vendor with `mise run
  gateway-api:vendor` (the `gateway-api` workflow fails until the file matches).
- **Host firewall** (Talos ingress firewall, `talos/all/06-firewall.yaml.tpl`
  plus `talos/control-plane/05-firewall.yaml.tpl`): default `block`; apid and
  the Kubernetes API from anywhere (mTLS), everything else only from the node
  LAN (`lanSubnet`) and, where pods scrape or call it, the pod CIDRs. A new
  hostNetwork listener (an exporter, a DaemonSet with `hostNetwork: true`) needs
  a rule there, otherwise it is silently dropped. Pods and LoadBalancer
  services are not affected (Cilium handles them in eBPF), except the
  Gateway's Envoy, which runs in the host and needs `gateway-ingress`
  (80/443). cilium-health also probes each node's IPv6 address on 4240, so
  `node-agents-ingress` allows the LAN's IPv6 /64 (`lanSubnetV6`, a GUA of
  the fiber prefix). Cilium picks that address only when the agent starts: if
  the prefix changes, update `lanSubnetV6` and `kubectl -n kube-system rollout
  restart ds/cilium`, otherwise `cilium-health status` shows the nodes
  unreachable over IPv6. Roll out with `talosctl apply-config --mode=try --timeout 6m` on one
  node first (topf's `try` reverts after 1m).
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
  RecurringJobs `backup-daily` (01:30, retain 7) and `backup-weekly` (Sundays
  00:30, retain 4) in `infrastructure/configs/longhorn` back up every volume of
  the group `default`, i.e. every volume without its own recurring-job labels.
  The VMRule `backups` alerts on failed Longhorn backups and a stale etcd backup.
  StorageClass `longhorn-single` (1 replica, `best-effort` locality, `Retain`) is
  for volumes that replicate in the application (CNPG); it is not strict-local on
  purpose, so the drain policy can still evict the single replica. Its volumes are
  in the group `default` too, i.e. also in the Longhorn backups.
  The UI at `longhorn.${GATEWAY_DOMAIN}` is behind the gateway's Authelia
  ExternalAuth, restricted to the LDAP group `cluster-admin`; its HTTPRoute is
  still called `registry-route` because it was adopted under that name.
- **Public Gateway** (`public` in `gateway-default`,
  `infrastructure/base/gateway/public.yaml`): the only internet-facing entry
  point, HTTPS 443 only (no port 80), `wildcard-tls`, routes only from namespaces
  labelled `homelab/public-routes: "true"` (today `sso`, only its authelia
  route, and `immich`; lldap stays internal). Its Service is selected by the pool
  `public-gateway` (`public: "true"`, own IPv4 /32 and IPv6 /64 outside the
  internal pool), with the fixed addresses `${PUBLIC_GATEWAY_IPV4}` /
  `${PUBLIC_GATEWAY_IPV6}` from the annotation `lbipam.cilium.io/ips`; Cilium
  announces them over BGP like every LoadBalancer address. The Cloudflare
  external-dns publishes only the hostnames listed in the Gateway's own
  annotation, pointing at `${PUBLIC_IPV4}` (the fixed FTTH IPv4) and
  `${PUBLIC_GATEWAY_IPV6}`. **Split DNS**: inside the LAN the same name must
  resolve to the internal Gateway `cilium`, so the router needs no NAT loopback
  and Authelia sees real client addresses; see "Split DNS" below. The router
  side is in `unifi/port_forwards.tf`: the DNAT `unifi_nat.public_gateway_https`
  (TCP 443 arriving on the FTTH WAN, translated to `firewall_cidrs.public_gateway_v4`;
  deliberately not a `unifi_port_forward`, which adds an unrestricted MASQUERADE
  and hides every IPv4 client behind the router), the WAN_IN rule
  `allow_public_gateway_v4` (a custom DNAT does not open the firewall; group
  `public_gateway_v4`) and the WANv6_IN rule `allow_public_gateway_v6` (group
  `public_gateway_v6`). There is no NAT loopback: LAN clients use split DNS. Changing
  an address means changing `cluster-secrets` and `firewall_cidrs` together.
  Because the portal is public, Authelia sets `regulation` (a username is
  banned for 1h after 5 failed logins in 10m, mode `user` only: the client IP
  arrives as an unverified X-Forwarded-For) and a zxcvbn `password_policy`
  (min score 3, for passwords set through the portal); every policy is
  `two_factor`, so a password alone opens nothing.
- **Split DNS** (`infra-external-dns-internal`, namespace `external-dns`): a
  second external-dns (`releaseName: external-dns-internal`, provider
  `rfc2136`, source `gateway-httproute` limited to the parent Gateway
  `cilium` by `--gateway-name`/`--gateway-namespace`, so the Gateway's status
  addresses become the targets) keeps the A/AAAA records of the public hosts
  in Technitium's zones `sso.${GATEWAY_DOMAIN}` and `immich.${GATEWAY_DOMAIN}`
  pointing at the internal Gateway. Each zone (member of the cluster catalog) and the TSIG key
  `external-dns-internal` (hmac-sha256; dynamic update and zone transfer
  allowed only from the pod CIDRs, for the zone and its wildcard) are set up
  **by hand in Technitium, not in git**; the key's secret is copied into the
  sops Secret `external-dns-internal-tsig`. A catalog member zone uses the
  catalog's zone-transfer rules (only the catalog's key) unless
  `overrideCatalogZoneTransfer` is set: the zone has it, with both keys
  (`cluster-catalog.dns.svc.cluster.local` for `technitium-1`, and
  `external-dns-internal`) and the pod CIDRs; without it Technitium refuses
  external-dns's AXFR as "missing TSIG auth". Ownership TXT records live inside
  the zone (`txtPrefix: extdns-%{record_type}.`, owner `internal`);
  `policy: sync` and `--rfc2136-axfr` (reads the zone back) only touch that
  zone (`domainFilters`). LAN clients therefore reach SSO through Gateway
  `cilium`, the internet through `public`. To split another public host, add
  its zone to Technitium the same way (TSIG key, update and transfer ACL, catalog override) and
  its hostname to `domainFilters` and a `--rfc2136-zone`.
  Nodes and pods do not ask Technitium: CoreDNS forwards to the nodes'
  resolvers, the UDM. Without NAT loopback the public address is a dead end
  from inside (it reaches the UDM's own UI), which breaks every OIDC token
  exchange, so the UDM answers the name too: a third external-dns,
  `infra-external-dns-udm` (`releaseName: external-dns-udm`, provider
  `webhook` with the UniFi sidecar `external-dns-unifi-webhook`, same
  Gateway `cilium` source, owner `udm`, same `txtPrefix`), keeps the A/AAAA
  records in the UDM's local DNS, so new Gateway addresses follow by
  themselves. The webhook uses the UniFi Integration API with an API key
  (`https://unifi.${GATEWAY_DOMAIN}/network/default/integrations`; the settings search does not find it), in the sops Secret
  `external-dns-udm-unifi` (`UNIFI_HOST`, `UNIFI_API_KEY`); it replaces the
  former static tofu records, which it adopted through ownership TXTs created
  by hand (`extdns-a`/`extdns-aaaa.sso.${GATEWAY_DOMAIN}`, TXT content in
  quotes: the UDM rejects an unquoted comma). Records external-dns creates
  itself need no such step.
  Which Gateway the traffic uses is visible in Envoy's metrics: the Cilium
  chart's `envoy.prometheus.serviceMonitor` scrapes cilium-envoy (9964, allowed
  by the host firewall), and the VMRule `sso-origin`
  (`infrastructure/configs/monitoring`) records `sso:envoy_upstream_rq:rate5m`,
  `sso:envoy_upstream_rx_bytes:rate5m` and `sso:envoy_upstream_tx_bytes:rate5m`
  with `origin` `internal` (Gateway `cilium`) or `external` (`public`). Other
  Envoy upstream clusters are named
  `gateway-default/cilium-gateway-<gateway>/<namespace>_<service>_<port>`.
- **Descheduler** (`kube-system`, CronJob `descheduler`, nightly at 03:00 and
  once at the end of `mise //talos:upgrade`) evens out CPU/memory requests with
  `LowNodeUtilization` (thresholds 20, targets 35, `nodeFit: true`), skipping
  kube-system, longhorn-system, flux-system, cert-manager and kyverno.
- **Intel iGPU** (`infra-intel-igpu`, namespace `intel-igpu`): three
  HelmReleases, `nfd` (node-feature-discovery, worker on every node), then
  `intel-device-plugins-operator` (amd64 only, webhook certificate from a
  cert-manager Issuer, hence `dependsOn: infra-cert-manager`), then
  `intel-device-plugins-gpu`, which creates the `GpuDevicePlugin` and the two
  NodeFeatureRules. NFD labels the nas `intel.feature.node.kubernetes.io/gpu=true`,
  the plugin runs only there and exposes `gpu.intel.com/i915` (`sharedDevNum: 2`:
  Immich's server and machine-learning pod take one each). The namespace is
  `privileged` for the hostPath mounts. The CRDs are not removed with the charts.
- **NAS storage** (`infra-nas-storage`, namespace `nas-storage`, privileged):
  the nas node has an mdadm RAID5 (`nas-data`, metadata 1.2, homehost `talos`)
  over its 2 TB NVMes, **not** the 1 TB `nvme3n1` (EPHEMERAL + Longhorn). Talos
  1.14's `RAIDArrayConfig` only does raid1, so `mise //talos:raid-create`
  builds the array once from a privileged alpine pod and `raid-add` grows it
  (reshape, then `xfs_growfs`). Talos assembles it at boot (udev, symlink
  `/dev/disk/by-id/md-name-talos:nas-data`) and mounts the xfs through the
  `ExistingVolumeConfig` in `talos/node/nas/` (the per-node patch directory of
  topf) at `/var/mnt/nas-data`, which also loads `raid456` and `nfsd` and opens
  TCP 2049 in the host firewall. At boot udev sees the disks before `raid456`
  is loaded, so md127 sits `inactive` ("personality for level 5 is not
  loaded") until Talos's `MDLastResortController` force-runs it about 30 s
  later and the mount follows; that is expected, not a failure. An interrupted
  resync resumes from the bitmap. Never
  touch disks that back a Talos volume; the raid tasks refuse them. A
  Deployment pinned to nas runs the kernel nfsd (alpine + nfs-utils, NFSv4.2,
  hostNetwork) exporting `/var/mnt/nas-data/nfs` to `${LAN_SUBNET}`; clients use
  `${NAS_IP}`. Its initContainer fails unless `/var/mnt/nas-data` is a real
  mountpoint. `csi-driver-nfs` provides StorageClass `nas-nfs` (RWX from any
  node, one directory per PV, `Retain`); local-path-provisioner provides
  `nas-local` (volumes under `/var/mnt/nas-data/local`, consumers pinned to nas,
  `Delete`) and `nas-local-retain` (same, but `Retain`, for data that must
  outlive its PVC; no `pathPattern`, which local-path only accepts nested and
  the setup script's marker check needs flat).
- **SQLite apps run a litestream sidecar** replicating to Wasabi S3 — the pattern
  to copy is `apps/mealie` or `apps/sso`. Pods carry `litestream: "true"` so the
  shared PodMonitor scrapes them. Restic backups of all apps (homeassistant,
  matter, node-red, knx-editor, paperless, scrypted, mealie, immich) go to one shared
  repo, monitored by a single `restic-exporter` in `monitoring` (no per-app
  exporter sidecars). Each runs `ghcr.io/jigfox/restic-sidecar` (source:
  `github.com/jigfox/restic-sidecar`) as a backup sidecar plus a
  `restic-restore` initContainer that fills an empty volume from the latest
  snapshot of its `RESTIC_HOST`. The repository password and its Wasabi key
  exist **only** in `cluster-secrets` (`RESTIC_PASSWORD`,
  `RESTIC_AWS_ACCESS_KEY_ID`, `RESTIC_AWS_SECRET_ACCESS_KEY`); the app Secrets
  and the exporter's hold `${VAR}` placeholders, so never put copies there.
  The same `RESTIC_AWS_*` key is used by litestream and Longhorn's backup
  target: it is the Wasabi user `backup-writer`, managed with OpenTofu in the
  private repo `jigfox/wasabi` (rotate there, then `mise run export-key`). The
  bucket is versioned and keeps overwritten/deleted objects for 30 days;
  `backup-writer` may delete objects but not versions, and cannot change
  versioning, lifecycle or the bucket, so a leaked key cannot destroy the
  history. Restoring an old version needs the admin key from `jigfox/wasabi`.
  Every restic container must set `RESTIC_PASSWORD` from its Secret, otherwise
  the image falls back to its public default and fails to open the repository.
  Backups start 8 minutes apart and each pod runs `restic check` on its own
  weekday, because `forget`, `check` and `prune` need the repository
  exclusively; `--retry-lock` in `RESTIC_FORGET_ARGS` (10m) and
  `RESTIC_BACKUP_OPTIONS` (30m) covers the rest, so set both on a new sidecar.
  `forget` alone never frees space: the CronJob `restic-prune`
  (`infrastructure/base/restic-maintenance`, Sundays 03:04) prunes the repo.
  With `backup-writer` its deletes are only delete markers, gone for good after
  the 30 days. The CronJob `etcd-backup` (`infrastructure/base/etcd-backup`,
  daily 02:20 on a control plane) takes a `talosctl etcd snapshot` through the
  Talos API (`talos/control-plane/04-talos-api-access.yaml` allows only role
  `os:etcd:backup` in that namespace) and stores it as restic host `etcd`;
  restore with `restic restore latest --host etcd`, then
  `talosctl bootstrap --recover-from`. Rotating the
  password: `restic key add`, update `cluster-secrets`, restart the restic pods
  and the exporter, then `restic key remove` the old key.
- **`require-resources`** (Kyverno ClusterPolicy, `infrastructure/configs/kyverno`)
  flags Pods whose containers lack CPU/memory requests or a memory limit. It is
  in `Audit` mode for now; check `kubectl get policyreport -A`. Excluded
  namespaces, because their pods aren't ours to template: `kube-system` (Talos
  static pods, metrics-server), `longhorn-system` (instance-manager and CSI pods
  created by the operator) and `intel-igpu` (the operator creates the GPU
  plugin DaemonSet from the `GpuDevicePlugin` CR, which has no `resources`
  field, so it can't be templated; the operator and NFD do carry resources).
- **KRR** (`infra-krr`, namespace `krr`) replaces Goldilocks/VPA. A Deployment
  runs `krr simple` against VMSingle (14d history, CPU p95, memory max + 15%)
  once a day, writes an HTML report to an emptyDir and serves it with nginx at
  `krr.${GATEWAY_DOMAIN}`, behind the gateway's Authelia ExternalAuth (group
  `cluster-admin`, domain rule in `apps/sso`, ReferenceGrant for the `krr`
  namespace). Locally `mise run krr [args]` port-forwards VMSingle and runs
  `krr simple` (krr cannot discover it itself). The mise pin is 1.29.0 because
  the macOS binaries of 1.30+ crash on start; the image is 1.31.1. krr skips
  only `kube-system`.
- **Monitoring** (`infra-monitoring`, namespace `monitoring`):
  `victoria-metrics-k8s-stack` (VMSingle 30d on a 20Gi volume, vmagent, vmalert,
  VMAlertmanager, operator, kube-state-metrics, node-exporter) plus Grafana.
  Grafana is stateless: every dashboard is a `defaultDashboards.sources` entry in
  `infrastructure/base/monitoring/release.yaml` (pinned grafana.com revisions or
  tags, bumped by Renovate) or comes from a chart (Cilium), and the sync-job
  turns them into ConfigMaps for the sidecar. Dashboards edited in the UI are
  lost on restart. For new scrapes and rules prefer the VM CRs (`VMServiceScrape`,
  `VMPodScrape`, `VMRule`), placed in `infrastructure/configs/monitoring/`
  (`infra-monitoring-config`, after the CRDs exist); ServiceMonitors, PodMonitors and PrometheusRules from
  charts are converted automatically (`prometheus-operator-crds` provides those
  CRDs). Alertmanager config, including the inhibit rules, lives in the same
  release. Grafana logs in only through Authelia (native OIDC, client
  `grafana`, secret in `grafana-oauth`); LDAP group `cluster-admin` maps to
  Admin, everyone else is refused. Grafana is also the alerting UI (vmalert rules
  via the VictoriaMetrics datasource, silences via the Alertmanager one).
  vmui (`prometheus.`), vmalert and Alertmanager (`alerts.`) sit behind the
  gateway's Authelia ExternalAuth (`ui-routes.yaml`, `cluster-admin` only); keep
  the chart's own `route` blocks disabled.
- **Technitium DNS** (`apps/technitium`, namespace `dns`) replaces AdGuard Home on
  the LAN: StatefulSet of two pods (anti-affinity, PDB), each with its own
  LoadBalancer Service (`technitium-dns-a`/`-b`, port 53, `externalTrafficPolicy:
  Local`) on fixed dual-stack addresses `${DNS_A_IPV4}`/`${DNS_A_IPV6}` and
  `${DNS_B_IPV4}`/`${DNS_B_IPV6}` from the internal LB pool. First-start env
  (admin password in the sops Secret, DoH forwarders, blocking and block lists,
  recursion ACL `${DNS_RECURSION_ACL}`: private ranges plus the LAN's IPv6 prefix,
  never an open resolver) only applies to an empty `/etc/dns`. Clustering
  (primary `technitium-0`, secondary `technitium-1`) is joined once by hand via
  the API over the per-pod ClusterIP Services (HTTPS 53443; node names are
  `technitium-N.dns.svc.cluster.local`). **Configuration is mostly not in git** (zones,
  cluster state; the allow/block lists, block list URLs and the Query Logs app
  are, see "technitium operator"): it lives in the PVCs and the restic backups
  (`56 * * * *`, check Sundays 05:30, `RESTIC_HOST` = pod name). The cluster
  syncs allowed/blocked domains from the primary to the secondary within
  seconds, but **not app settings**: those must be set on both servers. The
  "Query Logs (Sqlite)" app keeps 3 days (`maxLogDays`); at 7 days its ~610 MB
  database plus SQLite's temporary files during cleanup filled the original
  1Gi PVCs, which were grown to 3Gi by hand (the StatefulSet's
  `volumeClaimTemplates` still say 1Gi, they are immutable). The
  allow/block lists, block list URLs and the app settings are taken into git by
  the technitium operator (see its bullet). The UI is
  `dns.${GATEWAY_DOMAIN}` -> `technitium-0`; login is Technitium's native OIDC
  (Authelia client `technitium`, client secret in `technitium-secrets` key
  `OIDC_CLIENT_SECRET`, only kept so it is recoverable; LDAP group
  `cluster-admin` is mapped to Technitium's Administrators group, sign-up only
  for mapped users). The SSO settings live in Technitium's config, not in git.
  The local `admin` (password in `technitium-secrets`) stays as break-glass.
  The cluster catalog zone's zone transfer ACL must include the pod CIDRs
  `10.244.0.0/16` and `fd00:10:244::/48` (TSIG still required), because
  Technitium checks the source IP and pods transfer from their pod IP, not the
  per-pod ClusterIP. Technitium resets the ACL to the ClusterIP whenever
  `technitium-0` starts, so the CronJob `technitium-catalog-acl` (every 10 min,
  idempotent) widens it again; without it the secondary's zones stop syncing
  (`syncFailed`) after every restart. NOTIFYs are refused
  for the same reason, so zone changes reach `technitium-1` on the SOA refresh
  (~5 min). The Talos nodes must NOT use it as resolver:
  it runs on the cluster it would be needed to bootstrap.
  `mask.icloud.com` and `mask-h2.icloud.com` are on Technitium's blocked list
  (NXDOMAIN, and must not be on its allow list, which wins), so iCloud
  Private Relay is off on the LAN: with it, Safari (and the Immich app's
  login sheet) reaches `*.${GATEWAY_DOMAIN}` through Apple's relay, which
  cannot reach the gateway's LAN addresses.
  Monitoring: `VMProbe`s `technitium-dns-udp`/`-tcp` (blackbox-exporter in
  `infra-monitoring`, modules `dns_udp`/`dns_tcp`, an external lookup against all
  four addresses every 30s) feed the VMRule `dns` (`TechnitiumDNSDown` per target
  5m, `TechnitiumDNSAllDown` critical 2m); the CronJob `technitium-health`
  (`5,35 * * * *`) fails if a zone on `technitium-1` has `syncFailed` or the primary
  is not `Connected`, which `KubeJobFailed` reports until the failed Job is
  removed (TTL 1h).
- **CNPG** (`infra-cnpg`, namespace `cnpg-system`): CloudNativePG operator plus the
  barman-cloud plugin (needs cert-manager for its own certificates). `Cluster`s
  live with their apps; metrics come from the VMPodScrape `cnpg` (the cluster
  option `enablePodMonitor` is deprecated), dashboard 20417 in Grafana.
- **Immich** (`apps/immich`, `immich.${GATEWAY_DOMAIN}`): plain manifests (the
  chart is OCI-only and lags the app version). Server, machine learning
  (`-openvino`) and Valkey are all pinned to the nas; the server (QuickSync,
  ffmpeg `qsv`) and ML each take one `gpu.intel.com/i915`. The library is the PVC
  `immich-library` on `nas-local-retain` (restic sidecar and restore
  initContainer in the server pod, host `immich`, minute 4, check Wednesdays 05:30;
  `thumbs/` and `encoded-video/` excluded); Postgres is the CNPG `Cluster` `immich-db` (2
  instances on `longhorn-single`, image `cloudnative-vectorchord`, extensions
  created in `postInitApplicationSQL`, WAL archive and a daily `ScheduledBackup`
  to `s3://backup.${GATEWAY_DOMAIN}/cnpg/immich` through the `ObjectStore`
  `immich-db-backup`). The app runs without superuser, so Immich's own database
  dump job is disabled (CNPG backs up). Settings are the plain-text config file
  `apps/immich/immich.json` (ConfigMap `immich-config`, `IMMICH_CONFIG_FILE`, the
  web UI's settings are then read-only); the initContainer `config` copies it to
  an in-memory volume and adds `oauth.clientSecret` from the sops Secret key
  `OAUTH_CLIENT_SECRET`. Login is OIDC only (Authelia client `immich`, authorization policy
  `immich`: LDAP group `immich` only; claim `immich_role` is `admin` for
  `cluster-admin` members, `user` otherwise); password login is off. Reachable from the internet through the public
  Gateway (second parentRef, split DNS zone `immich.${GATEWAY_DOMAIN}`; OIDC is
  its own authentication). Break-glass (README "Common tasks"):
  `passwordLogin.enabled: true` in `apps/immich/immich.json`, restart the server, then
  `immich-admin reset-admin-password`; `immich-admin enable-password-login`
  does nothing, because the config file overrides the database settings.
  The lldap group `immich` is an `LLDAPGroup` in `infrastructure/configs/lldap-groups/`.
- **Teable** (`apps/teable`, `teable.${GATEWAY_DOMAIN}`, internal only): Airtable-like
  database, Community Edition. The image has no release tags, so
  `ghcr.io/teableio/teable:latest` is pinned by index digest; Renovate bumps the
  digest but never automerges it (each build may migrate the database). It runs as
  root (no `runAsNonRoot`). Postgres is the CNPG `Cluster` `teable-db` (2 instances on
  `longhorn-single`, plain Postgres 17, WAL archive and a daily `ScheduledBackup` to
  `s3://backup.${GATEWAY_DOMAIN}/cnpg/teable`); the app reads the URI from the CNPG
  Secret `teable-db-app`. Valkey (`teable-valkey`) holds cache and queues without
  persistence; attachments are the PVC `teable-assets` on `longhorn` (default backup
  jobs). Login is OIDC only (Authelia client `teable`, authorization policy `teable`:
  LDAP group `teable`, `client_secret_post`); `PASSWORD_LOGIN_DISABLED=true`. The first
  user to log in becomes the instance admin. Break-glass: set it to `false` temporarily.
- **Authelia + lldap** (`apps/sso`) provide OIDC; apps authenticate against
  `https://sso.${GATEWAY_DOMAIN}` with password login disabled.
  Access is by LDAP group, deny by default: every OIDC client (defined in plain
  text next to the policies) names an `authorization_policy` from
  `identity_providers.oidc.authorization_policies` in
  `apps/sso/helmrelease-authelia.yaml`, which admits only its groups
  (`mealie`/`mealie-admins`, `paperless`, `knx`, `immich`, `teable`; Grafana and Technitium
  `cluster-admin`), and the ExternalAuth `access_control` rules only
  `cluster-admin`. A new user without groups can log in to the Authelia portal
  but nothing else. A new client gets its own policy and LDAP group (create it
  as an `LLDAPGroup` in `infrastructure/configs/lldap-groups/` first, otherwise the policy locks everyone out), never the bare
  `one_factor`/`two_factor` policies, which admit any user. Only the secrets are
  sops: the Secret `authelia-secrets` (`apps/sso/authelia-secrets.yaml`: LDAP bind
  password, OIDC JWKS key, one pbkdf2 `OIDC_CLIENT_SECRET_<CLIENT>` hash per client) is
  mounted by the chart (`secret.additionalSecrets`) at `/secrets/authelia-secrets/<key>`
  and referenced by `path` (the chart renders client secret paths as Authelia's
  `{{ secret }}` template filter). A new client's hash needs a new key there plus
  the `client_secret.path` in its plain entry. Editing the Secret needs a manual
  `flux reconcile helmrelease` and a pod restart (mounted files, not watched).
- **UniFi as code** (`infra-tofu-controller`, then `infra-unifi`): tofu-controller
  (HelmRelease in `flux-system`, runner pods run OpenTofu 1.12) reconciles the
  `Terraform` CR `unifi` (`infrastructure/configs/unifi/terraform.yaml`) against the
  module in `unifi/`, provider `ubiquiti-community/unifi` pinned exactly in
  `unifi/versions.tf`. The provider reads `UNIFI_*` from the sops Secret
  `unifi-credentials` (injected via `runnerPodTemplate.spec.envFrom`); module
  variables come from the sops Secret `unifi-vars` (`varsFrom`: each key is one
  variable, set to the raw value as a **string**, so a typed variable cannot
  receive an object; structured values are JSON text that `unifi/variables.tf`
  `jsondecode`s). The four LANs live in `unifi/networks.tf`: structure
  (name, purpose, VLAN, flags) in HCL, every address (subnet, DHCP range and
  DNS, domain name) in the key `networks` of `unifi-vars`, a JSON object keyed
  by resource name with `subnet`, `dhcp_start`, `dhcp_stop` and optional
  `domain_name`, `dhcp_dns`. To add a network: resource in `networks.tf`, entry
  in `networks` (`sops set` or `sops` on `vars.yaml`), `import {}` in
  `unifi/imports.tf` (temporary: delete after the first approved apply) if it
  already exists on the controller.
  DHCP reservations are `unifi_client.this` (`unifi/clients.tf`). Static DNS
  records are not managed (the former `unifi_dns_record.this` held only the
  sso records, now external-dns-udm's); the variable `dns_records` of
  `unifi-vars` stays declared but empty, because varsFrom passes every key. Clients are split
  so changes stay reviewable: the public half is `local.client_config` in
  `clients.tf` (slug -> optional `name`, `note`, `network`), the secret half
  the key `clients` of `unifi-vars` (slug -> `mac`, `fixed_ip`). Only clients
  that carry configuration are managed, not every known one. To add one, add
  a neutral slug (no names of people, no MAC) to `client_config` and its
  `mac`/`fixed_ip` to `clients` with `sops set`; the `check` block warns about
  a slug that is only in `unifi-vars`. A client the controller already knows
  additionally needs a temporary `import {}` in `unifi/imports.tf` (id =
  `nonsensitive()` MAC); the MAC then shows in the plan output of that
  run. The four WLANs are `unifi_wlan.{main,devices_2g,iot,eap}` (`unifi/wlans.tf`):
  structure in HCL, only the SSID per WLAN in the key `wlans` of `unifi-vars`
  (JSON keyed by resource name, `{ssid}`). Passphrases are in the key
  `wlan_passphrases` (`{main, devices_2g, iot, main_ppsk}`) and go out
  write-only (`passphrase_wo`, never in state): to rotate one, change it there
  **and** bump that WLAN's `passphrase_wo_version`, otherwise nothing is sent.
  The PPSK key of `main` is a normal sensitive attribute. The IPv6 DNS servers
  the Default network advertises are its `dhcp_v6_server` block (DHCPv6 server
  itself off, SLAAC), values in `networks.default.dhcp_v6_dns`.
  The four WANs are `unifi_wan.{ftth,cable,internet_2,lte}` (`unifi/wans.tf`) and the two
  WireGuard clients `unifi_vpn_client.{vpn_ams,vpn_fra}` (`unifi/vpn_clients.tf`), with the
  PPPoE credentials and ISP name in the key `wans` and tunnel addresses, peer endpoint and keys in
  the key `vpn_clients` of `unifi-vars` (the provider reads the WireGuard private key back, so it
  is a plain `private_key`). The PPPoE password is the plain `password` of `ftth`, not
  `password_wo`: it is never read back, so the provider keeps the configured value and a change
  in `unifi-vars` diffs (and an apply may reconnect the PPPoE session), while `password_wo` is
  re-sent on every update without ever diffing. The `lte` WAN is `type = "static"` in UniFi's
  model, but its address comes from the LTE modem, so there is nothing to manage; only its
  `load_balance` is left out (provider rejects the controller's -1). State is the Secret `tfstate-default-unifi` in
  `flux-system`. **Approval is manual** (`approvePlan` unset in git): every hour the
  controller plans and stops. Read the plan with `kubectl -n flux-system get
  terraform unifi` (the message shows the pending `plan-main-<sha>`) and the
  human-readable plan in the ConfigMap `tfplan-default-unifi`
  (`kubectl -n flux-system get cm tfplan-default-unifi -o yaml`). Approve on
  the cluster, not in git (a commit is a new revision and replans under a new
  id): `mise run unifi:approve` shows the pending plan, asks, sets
  `approvePlan` to its id and waits for the apply (by hand: `kubectl -n
  flux-system patch terraform unifi --type merge -p
  '{"spec":{"approvePlan":"plan-main-<sha from the message>"}}'`). It applies
  that plan once; Flux does not own the field, so the value just stays until
  the next approval.
  BGP is `unifi_bgp.this` (`unifi/bgp.tf`) from the template `unifi/bgp.conf.tftpl`, whose router ID,
  AS numbers and listen ranges are in the key `bgp` of `unifi-vars`. The plan shows the rendered
  config only as `(sensitive value)`, so review BGP changes in the template diff, and before
  approving run `mise run unifi:bgp-diff`: it renders the template with `unifi-vars` and diffs it
  against the live config on the UDM in clear text (terminal only). A broken FRR config
  drops the sessions to the Talos nodes and with them every LoadBalancer address, LAN DNS
  (Technitium) included: approve only when you can verify right away (`kubectl get
  ciliumbgpclusterconfig`, `cilium bgp peers`, a `dig` against Technitium).
  Keep the nodes as a `bgp listen range`: the Talos host firewall
  (`talos/all/06-firewall.yaml.tpl`) has no rule for TCP 179 because the nodes
  open the sessions; plain `neighbor`s would make the UDM connect inbound.
  Never switch to `auto`: changes to the LAN/VLAN 1 network or BGP can cut the
  cluster off from the router, so they stay manually approved. Locally,
  `mise run unifi:plan` and `mise run unifi:import-plan` (plan with
  `-generate-config-out=generated.tf`) run `tofu` against the same state
  (decrypted credentials and `unifi-vars` as `TF_VAR_*` only in the process environment; the generated
  `unifi/backend_local.tf` is gitignored).
  The controller still runs the classic (non zone-based) firewall: no zones,
  zone policies or traffic matching lists exist, and there is no port forward: the
  only inbound IPv4 path is the DNAT `unifi_nat.public_gateway_https`
  (`port_forwards.tf`, FTTH WAN only; prefer `unifi_nat` over
  `unifi_port_forward`, which masquerades).
  What exists is
  managed as `unifi_firewall_group` (`firewall_groups.tf`) and `unifi_firewall_rule`
  (`firewall_rules.tf`); the addresses, the
  WireGuard clients' IPv6 prefix and the public Gateway's `public_gateway_v4`
  (plain address) and `public_gateway_v6` (/64), are in the key `firewall_cidrs` of `unifi-vars`
  (JSON, slug -> CIDR). To add a rule or NAT rule, write the resource with a
  neutral name (ports, protocols and actions in HCL, addresses via a new slug in
  `firewall_cidrs`), plus a temporary `import {}` if it already exists.
  The IoT network (VLAN 100, `corporate`, IPv4 only, WLAN `iot` with client
  isolation) is locked down by `unifi_firewall_rule.iot_lan_in` (LAN_IN,
  20000-20007, order matters): established/related first, then the group
  `IoT Admins` (laptop-1's reservation and the WireGuard tunnel subnet) may
  open connections into IoT; IoT may reach only Technitium (53, also its DHCP
  DNS), mosquitto-lan (8883) and NTP, no other private address; only clients
  in the group `IoT Internet` (the Gardena gateway's reservation) reach the
  internet; `iot_local_*` (LAN_LOCAL) keep IoT off the router except DHCP. The
  LoadBalancer addresses are the slugs `dns_a`, `dns_b` and `mqtt` in
  `firewall_cidrs`: if they change in `cluster-secrets`, change them there too.
  A device moves to IoT with `network = "iot"` in its `client_config` entry
  and a `fixed_ip` in that subnet (wireless clients follow at once through the
  VLAN override; one with a static IP of its own must be switched to DHCP
  first; internet only if added to `IoT Internet`); a wired one also needs its
  switch port's native network set to IoT in `unifi/switch.tf`.
  The Work network (VLAN 3, `unifi_network.work`, IPv4 only) is for a work
  laptop (`laptop-2`, `network = "work"`, so a VLAN override on any AP) that
  gets the internet and nothing else: `work_lan_in` (LAN_IN 20100-20101) drops
  it towards every RFC1918 address and drops anything routed into it,
  `work_lan_local` (LAN_LOCAL 20100-20102) allows only DHCP and DNS to the
  router. Its DHCP hands out the router as resolver (no `dhcp_dns`), which
  forwards to the ISP: Technitium got in the way of the laptop's corporate VPN.
  The switch is
  `unifi_device.switch`: only ports with a `port_override` block are managed
  (merged by index, the rest keep their controller config; removing a block
  does not reset the port), `forget_on_destroy = false`, no MAC in git (the
  import ID is the device's controller ID). APs and the UDM's ports are not
  managed.
  The WireGuard road-warrior server is `unifi_vpn_server.wireguard`
  (`unifi/wireguard.tf`): UDP 51820 on the FTTH WAN (`wan2`, port 10), reachable over IPv4 and IPv6
  (`ip_version = "v4"` only picks the UI's WAN address; the IPv6 side is opened by
  `unifi_firewall_rule.allow_wireguard_ports`, keep it), the provider
  generates the server key (only in the in-cluster state), tunnel subnet and the pushed
  Technitium resolvers (IPv4 only: the controller drops IPv6 DNS entries) in the key
  `wireguard` of `unifi-vars`; the IPv6 tunnel subnet is `firewall_cidrs.wireguard_home_v6`, a
  GUA /64 of the fiber prefix (subnet id 77), so clients get global IPv6 without NAT66 and its
  firewall group and WANv6_OUT rule follow it; if the ISP prefix ever changes, update that key
  and the peers' `interface_ipv6`. Devices are `unifi_wireguard_peer.this`, one per slug in the
  key `wireguard_peers` (`interface_ip`, `interface_ipv6`, `public_key`, plus the private key
  for the profile task; tofu ignores it). Add a device: `mise run unifi:wg-add-peer <slug>`
  (openssl X25519 key pair, next free tunnel IPs, written with `sops set`, nothing printed),
  commit and push the changed Secret, approve the plan and
  run `mise run unifi:wg-profile <slug> --qr` (or `--out <file>`, mode 600, refused inside the
  repo; needs the applied server for its public key and `qr` from the `pipx:qrcode` mise tool).
  Profiles are full tunnel (`0.0.0.0/0, ::/0`) to the endpoint `ddns.host_name:51820`. Revoke a
  device: delete its slug from `wireguard_peers` (`sops unset` or `sops`) and apply. The
  endpoint's A (FTTH IPv4) and AAAA (FTTH IPv6) records were set once by hand at Cloudflare;
  both addresses are fixed, so no dynamic DNS (`unifi_dynamic_dns` could not bind the FTTH WAN anyway).
- **lldap operator** (`infra-lldap-operator`, namespace `lldap-operator`, after
  `sso`): `github.com/jigfox/lldap-operator` (README: CRDs, adoption, RBAC)
  manages lldap users, groups and memberships from CRs. Flux pulls the repo at
  a pinned tag (`GitRepository` `lldap-operator`) and applies its
  `config/default` (`infrastructure/base/lldap-operator/operator.yaml`: image
  pinned by digest, upstream Namespace dropped; Renovate
  bumps tag and digest as one group). It talks to lldap's HTTP API
  (`http://ldap.sso`, Service port 80 -> 17170; the network policy matches the container port 17170) as the lldap user `lldap-operator` (in
  `lldap_admin`, created by hand); URL and credentials are the sops Secret
  `lldap-operator-credentials`. Groups are `LLDAPGroup`s in
  `infrastructure/configs/lldap-groups` (`infra-lldap-groups`, namespace
  `lldap`); a new Authelia policy needs its group there first. Users are
  `LLDAPUser`s in the private repo `jigfox/homelab-users` (plain text), pulled
  by the Flux `GitRepository` `homelab-users` with a read-only deploy key (sops
  Secret `homelab-users-deploy-key`, `infra-homelab-users`) and applied by the
  Kustomization `users`. A user CR owns that user's memberships in managed
  groups only; existing users and groups are adopted, not recreated, and
  deleting a CR deletes the lldap object unless its `deletionPolicy` is
  `Orphan`. A user the operator creates (never an adopted one) gets one
  invitation: `--invite=authelia` makes it start Authelia's "Reset password?"
  flow, so the mail is Authelia's reset template with a link to set the first
  password (`spec.sendInvitation: false` skips it; `status.invitationSentAt`
  and the condition `InvitationSent` show the result). The former OpenTofu module took over this job; its state Secret
  `tfstate-default-lldap` and the lldap user `tofu` were removed by hand after
  the takeover, and `destroyResourcesOnDeletion` was false, so pruning the
  Terraform CR deleted nothing in lldap.
- **technitium operator** (`infra-technitium-operator`, namespace
  `technitium-operator`, after `technitium`): `github.com/jigfox/technitium-operator`
  (README: CRDs, adoption, pruning) reconciles Technitium's allowed and blocked
  domains, block list URLs and DNS app settings from CRs through the web API.
  Wiring as for the lldap operator: a `GitRepository` at a pinned tag, its
  `config/default` applied by `infrastructure/base/technitium-operator/operator.yaml`
  (image tag without `v` plus digest, upstream Namespace dropped, Renovate group
  `technitium-operator`). The `TechnitiumServer`s `primary` (`technitium-0`) and
  `secondary` (`technitium-1`) are in `infrastructure/configs/technitium`
  (`infra-technitium-config`), logging in as `admin` with `ADMIN_PASSWORD` from
  `technitium-secrets`. Block list URLs are set on `primary` only (they sync to
  the secondary); **app settings are per server**, so both carry the `Query Logs
  (Sqlite)` config. `TechnitiumAllowedDomain`/`TechnitiumBlockedDomain`s are
  plain text in the private repo `jigfox/homelab-dns` (one file per domain, named
  after the domain, `serverRef: primary`, listed in its `kustomization.yaml`),
  pulled by the `GitRepository` `homelab-dns` with a read-only deploy key (sops
  Secret `homelab-dns-deploy-key`, `infra-homelab-dns`) and applied by the
  Kustomization `dns-lists`; the domains themselves are deliberately not in this
  public repo. Existing entries are adopted. **The operator runs with `--dry-run`
  and `pruneUnmanaged` is false on both servers**: it only logs and emits Events
  for what it would change. Leaving dry-run (drop the arg in `operator.yaml`) and
  pruning are deliberate steps taken only after reading the dry-run output. The
  upstream ClusterRole's cluster-wide `get` on Secrets is patched out; the Role
  `technitium-operator-secrets` in `dns` (`secret-access.yaml`) lets the
  operator's ServiceAccount read only `technitium-secrets`. The `dns` network
  policy allows the operator on 5380.
- **Multus** gives Home Assistant a second interface on the LAN VLAN; its
  Kustomization depends on `infra-multus-config`.
- **MQTT** (`apps/mosquitto`, namespace `smarthome`): no anonymous access.
  Home Assistant connects in-cluster to `mosquitto.smarthome:1883` (ClusterIP,
  plaintext); the Tasmota plugs connect over TLS to
  `mqtt.${GATEWAY_DOMAIN}:8883` via the LoadBalancer `mosquitto-lan`, which
  exposes only 8883. The certificate is the cert-manager `Certificate` `mqtt`
  (RSA, so Tasmota validates it against Let's Encrypt's root with
  `SetOption132 1`); the `cert-reload` sidecar restarts mosquitto when it is
  renewed. The logins are the `users` key of the sops Secret
  `mosquitto-users` (`apps/mosquitto/secrets.yaml`), one `name:password` line
  each, hashed into the password file by the `auth` init container; restart
  mosquitto after adding one. A Tasmota's username is its topic
  (`tasmota_XXXXXX`), so the `%u` patterns in the ACL limit it to its own
  topics.
- **Tasmota plugs** (Pumpe `tasmota_46901C`, Router `tasmota_D73738`, and
  `tasmota_D76224`) live in the IoT VLAN: `clients`
  `tasmota-1`..`3` with `network: "iot"`, which for a wireless client is a
  VLAN override on its existing WLAN, so no WLAN change on the plug. They must
  use DHCP (`IPAddress1 0.0.0.0`): a static address from Default stays on the
  plug after the move and makes it unreachable. Their web UI and HTTP API
  (`/cm?cmnd=…`) need user `admin` and a per-plug `WebPassword`. The
  passwords live only in `devices/tasmota.yaml` (sops, `data.<topic>`), which never reaches the cluster. Read one with
  `sops -d --extract '["data"]["tasmota_46901C"]' devices/tasmota.yaml`.
  A new plug needs a `WebPassword` (and its entry there) plus its MQTT setup:
  a `users` line, `MqttUser`/`MqttPassword`, `MqttHost mqtt.${GATEWAY_DOMAIN}`,
  `MqttPort 8883`, `SetOption132 1`, `SetOption103 1`.
