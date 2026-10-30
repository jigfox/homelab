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
| Certificates  | cert-manager                                                                  |
| DNS           | external-dns                                                                  |
| Auth          | Authelia + lldap (OIDC), oauth2-proxy for apps without OIDC                   |
| Policy        | Kyverno (required resource requests)                                          |
| Observability | kube-prometheus-stack, KRR for resource sizing                                |
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

## Rotating the sops age key

The private key lives in `~/.config/sops/age/keys.txt` locally and in the
`flux-system/sops-age` Secret (key `sops.agekey`) in the cluster. The Secret is
created by hand, not from git. Flux decrypts with whatever is in that Secret,
so it must hold the new key **before** the re-encrypted files reach `main`,
and the old one until they do. An age identity file may hold several keys.

1. Keep the old key as `~/.config/sops/age/keys.txt.old`, generate the new one
   with `age-keygen -o ~/.config/sops/age/keys.txt`, put its public key in
   `.sops.yaml`, `talos/.sops.yaml` and `fnox.toml`, and re-encrypt every file
   with `sops updatekeys -y <file>` followed by `sops rotate -i <file>` (fresh
   data key). Commit on a branch, don't merge yet.
2. Give the cluster both keys (`replace`, not `apply`, so no
   `last-applied-configuration` annotation keeps a second copy of the keys):
   ```sh
   cat ~/.config/sops/age/keys.txt.old ~/.config/sops/age/keys.txt \
     | kubectl -n flux-system create secret generic sops-age \
         --from-file=sops.agekey=/dev/stdin --dry-run=client -o yaml \
     | kubectl replace -f -
   ```
3. Merge the branch, then `flux reconcile kustomization flux-system --with-source`
   and wait until `flux get kustomizations -A` is all Ready on the new revision.
   HelmReleases fed by a `valuesFrom` Secret need a
   `flux reconcile helmrelease -n <ns> <name>`.
4. Drop the old key from the cluster:
   ```sh
   kubectl -n flux-system create secret generic sops-age \
       --from-file=sops.agekey=$HOME/.config/sops/age/keys.txt \
       --dry-run=client -o yaml \
     | kubectl replace -f -
   ```
5. Check which public keys the cluster holds:
   ```sh
   kubectl -n flux-system get secret sops-age -o jsonpath='{.data.sops\.agekey}' \
     | base64 -d | age-keygen -y
   ```

Rotating the key doesn't protect values already in git history: anything the
old key could decrypt has to be rotated at its source (API tokens, S3 keys,
OIDC client secrets, …).

## Public repository

This repository is public. CI and a pre-push hook enforce that no secrets,
private IP addresses, MAC addresses or the cluster's domain are committed;
such values live in sops-encrypted files and are referenced as `${VAR}`.

See [`CLAUDE.md`](CLAUDE.md) for detailed conventions.
