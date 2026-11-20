# hammerspace-tier0-k8s-daemonset

A DaemonSet that exports each Kubernetes worker's local NVMe (`/local`) over NFSv3 and attaches it to Hammerspace as a Tier0 storage volume.

Namespace `storage`, runs on nodes labelled `hammerspace-tier0=enabled`.

## Contents

`knfsd-nfs3-hammerspace.yaml` holds:

| Object | Purpose |
|---|---|
| ConfigMap `hammerspace-attach` | `run-attach-loop.sh`, `attach-hammerspace.sh`, `reset-hammerspace-volume.sh`: register the node and add `<node>::/local` as a Hammerspace storage volume through the management API (`/mgmt/v1.2/rest`). The loop does nothing while the sentinel `/local/Hammerspace` exists. |
| ConfigMap `knfsd-exporter` | `start-nfs.sh`: starts rpcbind, statd, mountd and kernel nfsd (NFSv3 only) and exports `/local`. |
| DaemonSet `knfsd-nfs3-hammerspace` | Containers `knfsd` (privileged, hostNetwork) and `attach`. |

Not included, create them separately:

- Namespace `storage`
- Secret `hammerspace-creds` with key `password` (Hammerspace admin password)

```bash
kubectl create namespace storage
kubectl -n storage create secret generic hammerspace-creds --from-literal=password='<hammerspace-admin-password>'
kubectl apply -f knfsd-nfs3-hammerspace.yaml
```

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
- After a volume has been missing, Hammerspace can keep a stale capacity of 0 bytes for the logical volume for several minutes (`Cannot add a volume which has 0 bytes of storage capacity`). The attach loop retries only once after `GRACE_SECONDS` (90 s), so a manual `kubectl -n storage exec <pod> -c attach -- bash /scripts/attach-hammerspace.sh` may be needed once the capacity shows up.
- The reset path deletes the Hammerspace volume with `bypassDecommission=DataLossRiskAcknowledged`, which wipes the Tier0 data on that node.
