# hammerspace-tier0-k8s-daemonset

A DaemonSet that exports each Kubernetes worker's local NVMe (`/local`) over NFSv3 and attaches it to Hammerspace as a Tier0 storage volume.

Namespace `storage`, runs on nodes labelled `hammerspace-tier0=enabled`.

## Contents

Source of truth, copied from `k8s-m1:/hammerspace/nfs-server-local`.

| File | Purpose |
|---|---|
| `knfsd-nfs3-daemonset.yaml` | The manifest (objects below) |
| `deploy.sh` | Creates namespace `storage` and applies the manifest |
| `remove.sh` | Deletes everything in the manifest |
| `add-label.sh` | Labels k8s-w1..w3 with `hammerspace-tier0=enabled` |

`knfsd-nfs3-daemonset.yaml` holds:

| Object | Purpose |
|---|---|
| ConfigMap `hammerspace-attach` | `run-attach-loop.sh`, `attach-hammerspace.sh`, `reset-hammerspace-volume.sh`: register the node and add `<node>::/local` as a Hammerspace storage volume through the management API (`/mgmt/v1.2/rest`). The loop does nothing while the sentinel `/local/Hammerspace` exists. |
| ConfigMap `knfsd-exporter` | `start-nfs.sh`: starts rpcbind, statd, mountd and kernel nfsd (NFSv3 only) and exports `/local`. |
| DaemonSet `knfsd-nfs3-hammerspace` | Containers `knfsd` (privileged, hostNetwork) and `attach`. |

Not in this repo: the Secret `hammerspace-creds` (key `password`, the Hammerspace admin password). On m1 it is created by `add-password.sh`, which is kept out of git because it contains the password.

## Deploy

```bash
./add-label.sh
kubectl create namespace storage
kubectl -n storage create secret generic hammerspace-creds --from-literal=password='<hammerspace-admin-password>'
./deploy.sh
```

Check that the files match the cluster before and after changes:

```bash
kubectl diff -f knfsd-nfs3-daemonset.yaml   # exit 0 = no differences
```

## NFS access: Hammerspace nodes only (dynamic)

`/local` is exported only to the Hammerspace Anvil and DSX nodes, not to the whole subnet:

- `refresh-allow-hosts.sh` (attach container) asks the Hammerspace API every `ALLOW_REFRESH_SECONDS` (300 s) for every IP of the nodes with `productNodeType` ANVIL or DSX, except interfaces whose only role is HA. Floating IPs are not included. The list goes to `/var/lib/hammerspace-tier0/allow-hosts` on the node, so the last known list survives pod restarts and reboots. The file is only replaced when the API returns a non-empty, valid list.
- `start-nfs.sh` (knfsd container) writes one export entry per IP and re-exports with `exportfs -ra` within `WATCH_SECONDS` (30 s) when the file changes. New Anvil/DSX nodes are added, removed ones dropped, without a restart.
- Fallback while no list exists yet: `HS_ALLOW_FALLBACK` if set, otherwise the subnet of the node's own interface (e.g. `10.49.101.0/24`).

Export options: `rw,sync,secure,no_subtree_check,no_root_squash,sec=sys`.

```bash
showmount -e <node-ip>                                    # -> only the Anvil/DSX IPs
kubectl -n storage exec <pod> -c knfsd -- cat /hsallow/allow-hosts
```

## Attaching the volume to Hammerspace (attach container)

`run-attach-loop.sh` runs forever:

- While `/local/Hammerspace` (the sentinel Hammerspace creates on the volume) exists, it only checks every `CHECK_SECONDS` (300 s) and makes no REST calls.
- When the sentinel is missing, `attach-hammerspace.sh` registers the node if needed, **waits until Hammerspace reports a capacity > 0** for the `/local` logical volume (up to `LV_WAIT_TRIES` × `LV_WAIT_SECONDS` = 15 min; Hammerspace refreshes it only every few minutes and rejects 0-byte volumes), then adds `<node>::/local` and polls the task for up to 5 min (`WAIT_TRIES` × `WAIT_SECONDS`).
- If that fails or the sentinel does not appear within `GRACE_SECONDS` (90 s), it retries every `RETRY_SECONDS` (300 s). **It never deletes the volume** unless `AUTO_RESET=true` is set.
- `apk add` is retried every 30 s instead of crashing when the package mirror is not reachable (typical right after a reboot).

Manual reset (deletes the Hammerspace volume; with `BYPASS_DECOMMISSION=true` this wipes the Tier0 data on that node):

```bash
kubectl -n storage exec <pod> -c attach -- bash /scripts/reset-hammerspace-volume.sh
```

## Safety checks and tuning in start-nfs.sh

- `/local` must be on an NVMe/MD device. Otherwise nothing is exported and the container restarts after `MOUNT_WAIT_SECONDS` (60 s). The `mp` export option cannot do this here, because `/local` is always a bind mount inside the container.
- After start, NFS v3 (100003) must be registered with rpcbind, and `exportfs` must not print warnings; otherwise the container restarts. The watch loop restarts it too if NFS drops out of rpcbind.
- Tuning from the Hammerspace Tier0 recommendations (see [BeratUlualan/Ansible-Tier0-1](https://github.com/BeratUlualan/Ansible-Tier0-1), role `perf_tuning`): `NFSD_THREADS=128`, read-ahead `READ_AHEAD_KB=4096` on the `/local` device, and host-wide TCP sysctls (`rmem/wmem_max` 256 MB, `tcp_rmem/tcp_wmem` up to 256 MB, `netdev_max_backlog` 250000, `tcp_mtu_probing=1`). Not applied because they don't fit VMware workers with one NUMA node: `pool_mode=pernode`, IRQ pinning, RDMA, `nfsd_direct_io`.

## Rocky Linux 10.2 kernel (el10_2): nfsd start fix

After the worker kernel was updated to `6.12.0-211.74.1.el10_2` (2026-11-09), two things broke, one after the other:

1. **The knfsd container crashed.** Writing to `/proc/fs/nfsd/threads` failed with `sh: write error: I/O error`, and the kernel logged `NFSD: Failed to start, no listeners configured.` The new kernel no longer creates default listeners on its own.
2. **Hammerspace could not add the volume** after listeners were added by writing `tcp 2049` to `/proc/fs/nfsd/portlist`. nfsd ran and `showmount -e` worked, but NFS (program 100003) was never registered with rpcbind, so `rpcinfo -T tcp <node> nfs 3` returned "Program not registered". Hammerspace's `volume-add` then failed with the misleading message `'str' object has no attribute 'result', error code: 255`.

**Fix:** start nfsd with `rpc.nfsd`. It hands its sockets to the kernel, and those do get registered with rpcbind. Any nfsd left running from a previous container is stopped first, so it registers with the new rpcbind:

```sh
echo 0 > /proc/fs/nfsd/threads 2>/dev/null || true
rpc.nfsd -N 4 -N 4.1 -N 4.2 -V 3 -U -p 2049 "${NFSD_THREADS}"
```

Check from any host:

```bash
rpcinfo -T tcp <node-ip> nfs 3   # -> program 100003 version 3 ready and waiting
```

Notes:

- Only TCP is registered. `-U` has no effect with the nfs-utils 2.3.2 in the image; Hammerspace uses TCP.
- After a volume has been missing, Hammerspace can keep a stale capacity of 0 bytes for the logical volume for several minutes (`Cannot add a volume which has 0 bytes of storage capacity`). `attach-hammerspace.sh` now waits for the capacity before adding the volume.
