# My Homelab

GitOps-managed Kubernetes homelab: [Talos Linux](https://www.talos.dev) on four
Turing RK1 (arm64) nodes plus an x86 `nas` node, with [Flux](https://fluxcd.io)
reconciling everything in this repository into the cluster.

Nothing is applied by hand. Changes take effect by being merged into `main`;
Flux pulls it every minute.

## Stack

| Area          | Component                                                                     |
| ------------- | ----------------------------------------------------------------------------- |
| OS / nodes    | Talos Linux, configured with [topf](https://github.com/postfinance/topf)      |
| GitOps        | Flux CD, secrets encrypted with [sops](https://github.com/getsops/sops) + age |
| Networking    | Cilium (kube-proxy replacement, BGP, L2 announcements, Gateway API)           |
| Storage       | Longhorn, 3 replicas, backups to S3                                           |
| Certificates  | cert-manager + trust-manager                                                  |
| DNS           | external-dns                                                                  |
| Auth          | Authelia + lldap (OIDC), oauth2-proxy for apps without OIDC                   |
| Policy        | Kyverno (CA injection, required resource requests)                            |
| Observability | kube-prometheus-stack, Goldilocks/VPA for sizing                              |
| Scheduling    | descheduler (rebalances pods by requests)                                     |

## Layout

| Path                          | Contents                                                      |
| ----------------------------- | ------------------------------------------------------------- |
| `fluxcd/homelab/`             | One Flux Kustomization per unit; the dependency graph         |
| `infrastructure/sources/`     | HelmRepository definitions                                    |
| `infrastructure/base/<x>/`    | Infrastructure components (HelmReleases or manifests)         |
| `infrastructure/configs/<x>/` | CRs that need their component's CRDs first                    |
| `infrastructure/vars/`        | sops-encrypted `cluster-secrets` backing every `${VAR}`       |
| `apps/<name>/`                | One directory per application                                 |
| `talos/`                      | topf config (`topf.yaml`, patches, schematics) and mise tasks |

## Getting started

Tooling is pinned with [mise](https://mise.jdx.dev):

```sh
mise install            # repo-wide tools
cd talos && mise install  # talosctl, topf, tpi, cilium-cli
```

Reproduce CI locally (no sops key needed):

```sh
.github/scripts/render.sh /tmp/rendered
.github/scripts/helm-template.sh
python3 .github/scripts/checks.py vars | secrets | disclosures | versions
```

## Common tasks

```sh
mise //talos:upgrade [--dry-run]       # Talos upgrade, node by node, waits for Longhorn health
mise //talos:upgrade-k8s [--dry-run]   # Kubernetes upgrade via talosctl upgrade-k8s
mise //talos:schematic-ids             # image factory schematic IDs
mise run install-cilium                # bootstrap Cilium on a freshly reset cluster
```

Versions are set in `talos/topf.yaml` (`talosVersion`, `kubernetesVersion`);
bump them there, then run the matching task.

## Public repository

This repository is public. CI and a pre-push hook enforce that no secrets,
private IP addresses, MAC addresses or the cluster's domain are committed;
such values live in sops-encrypted files and are referenced as `${VAR}`.

See [`CLAUDE.md`](CLAUDE.md) for detailed conventions.
