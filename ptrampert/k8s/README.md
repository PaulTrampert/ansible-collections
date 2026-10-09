# Ansible Collection - ptrampert.k8s

Roles for building and maintaining kubeadm-based Kubernetes clusters on Ubuntu.

## Roles

| Role | Runs on | Purpose |
|---|---|---|
| `ptrampert.k8s.node` | every node | Kubernetes host prerequisites: swap off, kernel modules and sysctls, containerd (pinned to a release series), kubelet/kubeadm/kubectl (held at a fixed version), kubelet node IP. |
| `ptrampert.k8s.control_plane` | `control_plane` | A stable API server address, `kubeadm init` on the first node and `kubeadm join` on the rest, kubeconfigs for users, Helm, Flannel CNI, and the scheduling toggle. |
| `ptrampert.k8s.worker` | `workers` | `kubeadm join` with a short-lived token, then waits for the node to become Ready. |
| `ptrampert.k8s.local_path_provisioner` | one control-plane node | A `StorageClass` that provisions each volume as a directory on the node using it, with Rancher's local-path-provisioner. |
| `ptrampert.k8s.nfs_provisioner` | one control-plane node | A `StorageClass` that provisions each volume as a directory on an NFS export, using the kubernetes-csi NFS driver. |
| `ptrampert.k8s.rclone_restic_server` | one control-plane node | A restic REST server inside the cluster, `rclone serve restic`, storing the repositories on any rclone remote. |

Role inputs are documented in each role's `meta/argument_specs.yml` (`ansible-doc -t role ptrampert.k8s.<role>`).

Not supported yet: Kubernetes version upgrades, removing a node from the cluster.

## Inventory

The roles expect these groups:

- `control_plane`: control-plane nodes. The first host in the group creates the cluster; the rest join it.
- `workers`: worker nodes (may be empty for a single-node cluster).
- A parent group containing both, used to run `ptrampert.k8s.node` (e.g. `k8s_cluster`).

## The API server address

kubeadm writes one address — the *control plane endpoint* — into every kubeconfig and into the API server's certificate when the cluster is created, and **it cannot be changed afterwards**. A cluster created without one can never gain a second control-plane node: `kubeadm join --control-plane` refuses outright. So `ptrampert.k8s.control_plane` always configures one, even for a cluster that starts with a single control-plane node. That single node can then be grown into a highly available control plane later.

There are two ways to provide it, chosen with `control_plane_load_balancer`.

### Stacked (the default)

The control-plane nodes load balance for themselves. HAProxy runs on each of them and balances across every API server; keepalived floats `control_plane_vip` between them over VRRP, so exactly one node holds it at a time.

```
                clients, kubelets, workers
                           |
             control_plane_vip:8443   <-- keepalived moves this between nodes
                           |
                        HAProxy       <-- on whichever node holds the VIP
                    /      |      \
                 cp1      cp2      cp3
                        :6443 kube-apiserver
```

HAProxy uses port 8443 rather than 6443 because kube-apiserver already has 6443 on those hosts. Set `control_plane_lb_port` to change it.

Because every node's HAProxy knows every API server, the VIP serves the API wherever it lands — including on a node whose own API server is down, or has not been created yet. keepalived's health check watches the local HAProxy, not the API server, which is what lets the VIP be up for the very `kubeadm init` that creates the first API server.

```yaml
control_plane_vip: 192.0.2.10
```

VRRP uses IP protocol 112 and must be allowed between the control-plane nodes. The role sends it by unicast, so it works on networks that do not carry multicast.

### External

Something outside the cluster balances the API servers — a hardware load balancer, a cloud one, or a separate HAProxy host built with `ptrampert.general_services.haproxy`. The role installs no load balancer of its own.

```yaml
control_plane_load_balancer: external
control_plane_endpoint: k8s-api.example.com:6443
```

The load balancer must forward to every control-plane node on port 6443 and health-check them on `/healthz`.

## Adding a control-plane node

Put the new host in the `control_plane` group and run the playbook again. The role issues a fresh certificate key and join token from the first control-plane node and runs `kubeadm join --control-plane`; existing nodes are left alone. Control-plane nodes join one at a time, because each one is also an etcd member.

Run the playbook against the whole `control_plane` group rather than limiting to the new host: every node needs the addresses of the others to configure HAProxy and keepalived, and the role refuses to run if part of the group is missing from the play.

With `control_plane_load_balancer: external`, add the new node to the external load balancer's backends as well — the role does not manage it.

## Storage

Without a storage provider every `PersistentVolumeClaim` stays `Pending`, so a cluster that runs anything with state needs one. The collection has two. Each creates its own `StorageClass`, they can be installed side by side, and a workload picks the one it needs by naming its class. At most one of them should be the cluster default, the class a claim naming none gets.

### Node-local

`ptrampert.k8s.local_path_provisioner` installs Rancher's local-path-provisioner and a `StorageClass` that creates each volume as a directory under `local_path_provisioner_path` (by default `/opt/local-path-provisioner`, the same on every node) on the node where the claiming pod runs. The provisioner creates the directory itself; putting a separate filesystem under it is up to the operator.

The volume lives on one node, so a pod that claims it can only ever run on that node. That suits a single-node cluster, and anything whose data is disposable or replicated by the workload itself. A pod that must be free to move between nodes needs storage the nodes share: NFS, below.

Claims are bound `WaitForFirstConsumer`: the volume is created once the scheduler has picked a node for the pod, rather than on a node chosen before anything knows where the pod will run.

The class is not the cluster default unless asked:

```yaml
local_path_provisioner_storage_class_default: true
```

Deleting a claim deletes its data. Deleting a pod, Deployment or StatefulSet does not delete the claim, so ordinary redeployment keeps the data; set `local_path_provisioner_reclaim_policy: Retain` to keep the directory even when the claim goes away.

### Shared over NFS

`ptrampert.k8s.nfs_provisioner` installs the kubernetes-csi NFS driver and a `StorageClass` that creates each volume as a directory under an NFS share. Every node mounts the same share, so a pod keeps its data when it is rescheduled onto another node.

The export has to exist already, and both settings are required:

```yaml
nfs_provisioner_server: nfs.example.com
nfs_provisioner_share: /exports/kubernetes
```

The role builds no NFS server. Nothing about it assumes one kind of server either: a NAS, a cloud filer or a Linux host all serve the same purpose, and choosing and sizing one is a decision about a particular site rather than about the cluster.

The nodes need no NFS packages of their own. The driver's node plugin carries its own NFS client and mounts the share from inside its container.

Like the node-local class, it is not the cluster default unless asked:

```yaml
nfs_provisioner_storage_class_default: true
```

Deleting a claim deletes the volume's directory on the share. Deleting a pod, Deployment or StatefulSet does not delete the claim, so ordinary redeployment keeps the data. Set `nfs_provisioner_on_delete: archive` to have the driver rename a deleted volume's directory out of the way instead of removing it, or `nfs_provisioner_reclaim_policy: Retain` to keep the volume itself when its claim goes away.

Mount options default to `nfsvers=4.1` and are configurable, as is a `nfs_provisioner_sub_dir` under the share to keep the volumes in one place.

## Backup storage

`ptrampert.k8s.rclone_restic_server` runs `rclone serve restic` in the cluster, behind a `ClusterIP` Service. It speaks restic's REST backend protocol and stores the repositories on any rclone remote: a cloud drive, SFTP, an object store. Moving the backups somewhere else is then a change to the rclone config rather than to every client.

It is a storage endpoint only. What gets backed up, when, and how long it is kept belong to the restic clients, such as k8up.

```yaml
rclone_restic_server_config:
  offsite:
    type: sftp
    host: backup.example.com
    user: restic
    pass: "{{ vault_restic_sftp_pass_obscured }}"   # as `rclone obscure` prints it
rclone_restic_server_remote: offsite:restic
rclone_restic_server_users:
  - name: app1
    password_hash: "{{ vault_restic_app1_hash }}"
```

`rclone_restic_server_config` is the rclone config itself, a mapping of remote name to its settings, rendered as `rclone.conf`. It is passed through as given, so a `crypt` remote wrapping another one needs nothing from the role (restic encrypts its repositories anyway). Settings rclone keeps obscured must be given obscured.

Clients reach it at:

```
rest:http://<user>:<password>@rclone-restic-server.<namespace>.svc:8080/<user>/<repo>
```

### Users

Users are required, since without them `rclone serve restic` lets anyone in. Each user reaches only the repositories under `/<user>/` (`--private-repos`), so give every client its own user: then a client can neither read nor delete another one's backups. That is the access control. The cluster's CNI, Flannel, does not enforce `NetworkPolicy`, so the role creates none.

Users are given as a bcrypt hash rather than a password. That keeps what the role writes the same between runs, and the controller needs no hashing library. Generate one with `htpasswd` from `apache2-utils` and take what follows the colon:

```sh
htpasswd -nB app1
```

### The config is seeded, not managed

Remotes that sign in with OAuth (OneDrive, Google Drive, Dropbox and others) rewrite their token in `rclone.conf` every time rclone refreshes it, and a Secret mounts read-only. So the role stores the rendered config in a seed Secret, and an init container copies it to a small volume only when the volume holds no config yet. rclone runs against that copy, and refreshed tokens survive pod restarts. Changing `rclone_restic_server_config` afterwards does not touch an existing copy.

To set up an OAuth remote, run `rclone config` on a machine with a browser and copy the remote's section, `token` included, into `rclone_restic_server_config`, with the token in the playbook's vault.

To re-authorise one, after the token has been revoked or has expired:

1. Run `rclone authorize "<type>"` (for example `rclone authorize "onedrive"`) on a machine with a browser.
2. Put the new token in the seed value and run the playbook, which updates the seed Secret.
3. Delete the copy and the pod, so that the replacement seeds itself again:

   ```sh
   kubectl exec -n rclone-restic-server deploy/rclone-restic-server -c rclone -- rm /config/rclone.conf
   kubectl delete pod -n rclone-restic-server -l app.kubernetes.io/name=rclone-restic-server
   ```

Losing the volume means losing the refreshed token. The next pod falls back to the seed, which works as long as the provider still accepts it, and otherwise needs re-authorising.

The volume uses the cluster's default storage class unless `rclone_restic_server_storage_class` names another. On `local_path_provisioner` it lives on one node, and so does the pod. NFS lets the pod move.

### Append-only

`rclone_restic_server_append_only: true` refuses every delete or overwrite, so a compromised client cannot destroy its own backups. It also makes `restic forget --prune` fail, and k8up's `Prune` jobs rely on it. With it on, pruning has to run somewhere that writes the remote directly, for example `restic -r rclone:...` as below. It is off by default.

### Plain HTTP

The Service is only reachable from inside the cluster, but from every pod in every namespace. Traffic between nodes crosses Flannel's VXLAN unencrypted, HTTP Basic credentials included. restic encrypts the repository data itself.

### Restoring without the cluster

The server is only needed because k8up has no `rclone:` backend. After losing the cluster, plain `restic` on any machine with rclone opens a repository straight on the remote, running `rclone serve restic --stdio` itself:

```sh
restic -r rclone:offsite:restic/app1/<repo> snapshots
```

Configure the remote for that rclone as `rclone_restic_server_config` does. For an OAuth remote, the server's copy on its volume holds the freshest token.

The remote holds a restic repository, not browsable files. To take any snapshot, or a path inside one, out as a tarball:

```sh
restic -r rclone:offsite:restic/app1/<repo> dump --archive tar latest / | gzip > backup.tar.gz
```

The server runs with `--cache-objects=false`. With the cache on, it keeps serving objects it has seen after something else deletes them from the remote, such as a prune run this way.

## Example playbook

```yaml
- name: Prepare Kubernetes nodes
  hosts: k8s_cluster
  become: true
  roles:
    - ptrampert.k8s.node

- name: Bootstrap the control plane
  hosts: control_plane
  become: true
  roles:
    - ptrampert.k8s.control_plane

- name: Join worker nodes
  hosts: workers
  become: true
  roles:
    - ptrampert.k8s.worker

# Configures the cluster, not the host, so it runs once rather than on every
# control-plane node. Install either provider, or both.
- name: Install the storage providers
  hosts: control_plane[0]
  become: true
  roles:
    - ptrampert.k8s.local_path_provisioner
    # Needs nfs_provisioner_server and nfs_provisioner_share.
    - ptrampert.k8s.nfs_provisioner

- name: Serve backup storage
  hosts: control_plane[0]
  become: true
  roles:
    # Needs rclone_restic_server_config, _remote and _users.
    - ptrampert.k8s.rclone_restic_server
```

For a single-node cluster, put the host in `control_plane`, leave `workers` empty, and set `control_plane_schedulable: true`. It still gets a VIP, so it can grow a second control-plane node later.

On hosts with more than one network interface, set `node_ip`, `control_plane_advertise_address`, and `control_plane_flannel_iface` so the cluster uses the intended network. The VIP follows `control_plane_advertise_address` unless `control_plane_vip_interface` says otherwise.
