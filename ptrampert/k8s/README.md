# Ansible Collection - ptrampert.k8s

Roles for building and maintaining kubeadm-based Kubernetes clusters on Ubuntu.

## Roles

| Role | Runs on | Purpose |
|---|---|---|
| `ptrampert.k8s.node` | every node | Kubernetes host prerequisites: swap off, kernel modules and sysctls, containerd (pinned to a release series), kubelet/kubeadm/kubectl (held at a fixed version), kubelet node IP. |
| `ptrampert.k8s.control_plane` | `control_plane` | `kubeadm init` on the first node with the API server address it is given, `kubeadm join` on the rest, kubeconfigs for users, Helm, Flannel CNI, and the scheduling toggle. |
| `ptrampert.k8s.worker` | `workers` | `kubeadm join` with a short-lived token, then waits for the node to become Ready. |
| `ptrampert.k8s.local_path_provisioner` | one control-plane node | A `StorageClass` that provisions each volume as a directory on the node using it, with Rancher's local-path-provisioner. |
| `ptrampert.k8s.nfs_provisioner` | one control-plane node | A `StorageClass` that provisions each volume as a directory on an NFS export, using the kubernetes-csi NFS driver. |
| `ptrampert.k8s.rclone_restic_server` | one control-plane node | A restic REST server inside the cluster, `rclone serve restic`, storing the repositories on any rclone remote. |
| `ptrampert.k8s.k8up` | one control-plane node | The K8up backup operator, which backs up volumes and database dumps to restic repositories. |
| `ptrampert.k8s.cert_manager` | one control-plane node | cert-manager, with `ClusterIssuer`s for Let's Encrypt's staging and production directories that solve DNS-01 through any provider cert-manager supports. |

Role inputs are documented in each role's `meta/argument_specs.yml` (`ansible-doc -t role ptrampert.k8s.<role>`).

Not supported yet: Kubernetes version upgrades, removing a node from the cluster.

## Inventory

The roles expect these groups:

- `control_plane`: control-plane nodes. The first host in the group creates the cluster; the rest join it.
- `workers`: worker nodes (may be empty for a single-node cluster).
- A parent group containing both, used to run `ptrampert.k8s.node` (e.g. `k8s_cluster`).

## The API server address

kubeadm writes one address — the *control plane endpoint* — into every kubeconfig and into the API server's certificate when the cluster is created, and **it cannot be changed afterwards**. A cluster created without one can never gain a second control-plane node: `kubeadm join --control-plane` refuses outright. So `ptrampert.k8s.control_plane` requires one, `control_plane_endpoint`, even for a cluster that starts with a single control-plane node. That single node can then be grown into a highly available control plane later.

The role doesn't serve the endpoint itself. Whatever does has to be up before the role runs, and the role checks that something answers there before `kubeadm init`. It can be anything that forwards to port 6443 on every control-plane node:

- **HAProxy and keepalived on the control-plane nodes themselves**, from `ptrampert.general_services`, as below.
- **A load balancer outside the cluster**: a hardware one, a cloud one, or a separate host built with `ptrampert.general_services.haproxy`. It should health-check each API server on `/healthz`.
- **A DNS name.** The name is what's frozen into the cluster, not the address behind it, so a name keeps the most options open. It can point at a single node's address today and at a VIP or load balancer later.

```yaml
control_plane_endpoint: k8s-api.example.com:6443
```

### Load balancing on the control-plane nodes

The control-plane nodes can balance for themselves, with no separate host. HAProxy runs on each of them and balances across every API server. keepalived floats a VIP between them over VRRP, so exactly one node holds it at a time.

```
                clients, kubelets, workers
                           |
                   192.0.2.10:8443    <-- keepalived moves this between nodes
                           |
                        HAProxy       <-- on whichever node holds the VIP
                    /      |      \
                 cp1      cp2      cp3
                        :6443 kube-apiserver
```

The playbook composes it, in a play that runs before `ptrampert.k8s.control_plane`:

```yaml
# group_vars/control_plane.yml
api_vip: 192.0.2.10
api_lb_port: 8443
control_plane_endpoint: "{{ api_vip }}:{{ api_lb_port }}"

# Set explicitly, so nothing derives it from facts and picks up the VIP while
# this node happens to hold it. Give each host its own, in host_vars.
# control_plane_advertise_address: 192.0.2.11

# How the other nodes' HAProxy reaches this node's API server. Group vars rather
# than play vars, so every host can read the others' through hostvars.
api_backend:
  name: "{{ inventory_hostname }}"
  address: "{{ control_plane_advertise_address }}:6443"
api_vip_peers: >-
  {{ groups['control_plane'] | reject('eq', inventory_hostname)
     | map('extract', hostvars, 'control_plane_advertise_address') | list }}
```

```yaml
- name: Load balance the API servers on the control-plane nodes
  hosts: control_plane
  become: true
  vars:
    haproxy_listen:
      - name: kube-apiserver
        bind: "*:{{ api_lb_port }}"
        mode: tcp
        balance: roundrobin
        # The API server answers /healthz without credentials, so the check
        # tells a running API server from a listening socket.
        options: [tcplog, httpchk]
        extra:
          - "http-check send meth GET uri /healthz"
          - "http-check expect status 200"
        # Watches are long-lived connections; short timeouts would keep cutting them.
        timeouts: {connect: "5s", client: "1h", server: "1h"}
        server_options: "check check-ssl verify none inter 2s fall 3 rise 2"
        servers: "{{ groups['control_plane'] | map('extract', hostvars, 'api_backend') | list }}"

    keepalived_scripts:
      # The local HAProxy, not the API server: see below.
      chk_kube_apiserver_lb:
        command: "/bin/bash -c '</dev/tcp/127.0.0.1/{{ api_lb_port }}'"
        interval: 2
        fall: 2
        rise: 2
    keepalived_vrrp_instances:
      - name: kube-apiserver
        interface: eth0
        # BACKUP everywhere: let the election decide rather than have a node
        # claim the address before its HAProxy is up.
        state: BACKUP
        virtual_router_id: 51
        # Highest on the first host in the group, so the VIP settles there.
        priority: "{{ 150 - groups['control_plane'].index(inventory_hostname) }}"
        virtual_ipaddresses: ["{{ api_vip }}/24"]
        # Unicast VRRP works on networks that don't carry multicast. A lone
        # node has no peers, and keepalived refuses a unicast source with
        # nobody to send to.
        unicast_src_ip: "{{ control_plane_advertise_address if api_vip_peers else '' }}"
        unicast_peers: "{{ api_vip_peers }}"
        track_scripts: [chk_kube_apiserver_lb]
  roles:
    - ptrampert.general_services.haproxy
    - ptrampert.general_services.keepalived
```

Things to know about it:

- **HAProxy uses port 8443, not 6443**, because kube-apiserver already has 6443 on those hosts.
- **keepalived checks the local HAProxy, not the API server.** HAProxy answers whenever it is running, even before any API server exists, which is what lets the VIP be up for the `kubeadm init` that creates the first one. Every node's HAProxy has every API server as a backend, so the VIP serves the API wherever it lands, including on a node whose own API server is down.
- **VRRP uses IP protocol 112**, which must be allowed between the control-plane nodes.
- **On a single control-plane node** this puts HAProxy and keepalived in the critical path with nothing to fail over to. A DNS name pointing at the node is the leaner way to keep the option of growing later.

## Adding a control-plane node

Put the new host in the `control_plane` group and run the playbook again. The role issues a fresh certificate key and join token from the first control-plane node and runs `kubeadm join --control-plane`; existing nodes are left alone. Control-plane nodes join one at a time, because each one is also an etcd member.

Run the playbook against the whole `control_plane` group rather than limiting to the new host: the first node issues the join credentials for all the new ones at once, and the role refuses to run if part of the group is missing from the play.

Whatever serves `control_plane_endpoint` has to learn about the new node too. With the load balancing above, running the whole playbook does that, since its server list and VRRP peers follow the group. An external load balancer needs the node added to its backends by hand.

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

It is a storage endpoint only. What gets backed up, when, and how long it is kept belong to the restic clients, such as [K8up](#backing-up-workloads).

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
    password: "{{ vault_restic_app1_password }}"
```

`rclone_restic_server_config` is the rclone config itself, a mapping of remote name to its settings, rendered as `rclone.conf`. It is passed through as given, so a `crypt` remote wrapping another one needs nothing from the role (restic encrypts its repositories anyway). Settings rclone keeps obscured must be given obscured.

The role runs on one control-plane host and talks to the cluster through `kubernetes.core`, which needs the Python Kubernetes client. Ubuntu's package is older than `kubernetes.core` supports, so the role installs the client from PyPI into a venv under `/opt/rclone-restic-server`, at the version `rclone_restic_server_kubernetes_client_version` pins.

Clients reach it at:

```
rest:http://<user>:<password>@rclone-restic-server.<namespace>.svc:8080/<user>/<repo>
```

### Users

Users are required, since without them `rclone serve restic` lets anyone in. Each user reaches only the repositories under `/<user>/` (`--private-repos`), so give every client its own user: then a client can neither read nor delete another one's backups. That is the access control. The cluster's CNI, Flannel, does not enforce `NetworkPolicy`, so the role creates none.

The role stores each password as a bcrypt hash. The salt comes from the namespace and the user name rather than at random, so an unchanged password hashes the same on every run and the pod is only restarted when a password changes. Hashing happens on the controller, which needs bcrypt support: `passlib`, or a libc `crypt` that supports it, as libxcrypt on most Linux distributions does.

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

## Backing up workloads

`ptrampert.k8s.k8up` installs the [K8up](https://k8up.io/) operator. K8up is built on restic: backups are deduplicated, encrypted, and pruned according to a retention policy, and they can be restored either by K8up inside the cluster or with plain `restic` from any machine. The second matters after losing the cluster, because the data can come back before the cluster does.

The role installs the operator only. Where the backups go, the restic password, when backups run and how long they are kept are K8up resources, which belong to the playbooks that deploy the workloads.

It installs the upstream Helm chart at the version `k8up_version` pins; each chart version pins the operator release it runs. The chart keeps its CRDs in `crds/`, which Helm installs with the first release and never upgrades, so the role applies them itself, server-side, before every install or upgrade, and tells Helm to leave them alone. Like `rclone_restic_server`, it installs the Python Kubernetes client from PyPI into a venv under `/opt/k8up` for that.

Schedules are cron expressions in UTC unless `k8up_timezone` names another zone, such as `Europe/Zurich`. Anything else the chart offers goes through `k8up_chart_values`.

### What gets backed up

A backup of a namespace covers two kinds of data:

- **Volumes.** Every bound `PersistentVolumeClaim` in the namespace. K8up mounts each one in a backup pod and reads the files. A `ReadWriteOnce` claim is backed up on the node where a pod has it mounted, so node-local volumes from `local_path_provisioner` are backed up as well as NFS ones. A claim annotated `k8up.io/backup: "false"` is skipped. To make backups opt-in instead, so that only claims annotated `k8up.io/backup: "true"` are backed up:

  ```yaml
  k8up_chart_values:
    k8up:
      skipWithoutAnnotation: true
  ```

- **Dumps.** A pod annotated with a backup command has that command run inside it, and its output streams straight into restic. That gives a database a consistent backup, which copying its live data directory cannot:

  ```yaml
  metadata:
    annotations:
      k8up.io/backupcommand: sh -c 'pg_dump -U postgres app'
      k8up.io/file-extension: .sql
      # The container to run it in, when it is not the pod's first.
      k8up.io/backupcommand-container: postgres
  ```

  The command runs in one pod per owner, so a Deployment's replicas are dumped once. When the dump is what should be restored, annotate the database's own claim `k8up.io/backup: "false"` so its live files are not backed up as well.

Each claim and each dump becomes a restic snapshot of its own. Its host is the namespace, and its path `/data/<claim>` for a claim or `/<namespace>-<container><extension>` for a dump, such as `/app1-postgres.sql`.

K8up's backup and restore pods run as UID 65532. Files only their owner can read, such as a database's data directory, need `podSecurityContext` set on the `Schedule`'s `backup` (and on a `Restore`) to run as that owner, or as root.

### Backing up to the restic server

K8up's `rest` backend reaches `rclone_restic_server`. Give each namespace a user of its own on the server, then:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: backup-repo
  namespace: app1
stringData:
  repository-password: "{{ vault_app1_repository_password }}"
  username: app1
  password: "{{ vault_restic_app1_password }}"   # the user's rclone_restic_server_users password
---
apiVersion: k8up.io/v1
kind: Schedule
metadata:
  name: backup
  namespace: app1
spec:
  backend:
    repoPasswordSecretRef:
      name: backup-repo
      key: repository-password
    rest:
      url: http://rclone-restic-server.rclone-restic-server.svc:8080/app1/k8up
      userSecretRef:
        name: backup-repo
        key: username
      # Spelled this way upstream.
      passwordSecretReg:
        name: backup-repo
        key: password
  backup:
    schedule: "@daily-random"
  check:
    schedule: "@weekly-random"
  prune:
    schedule: "@weekly-random"
    retention:
      keepDaily: 7
      keepWeekly: 4
      keepMonthly: 6
```

The password field of the `rest` backend is spelled `passwordSecretReg` upstream. Give both it and `userSecretRef`, and leave the credentials out of `url`: K8up puts them into the URL itself. K8up creates the repository with its first backup.

The repository password is the only way into the backups. Keep a copy outside the cluster, in the playbook's vault, or losing the cluster loses the backups with it.

Against an append-only server, leave out `prune`, which would fail, and prune straight on the remote as [Restoring without the cluster](#restoring-without-the-cluster) shows.

Any backend K8up supports works the same way (S3, B2, another REST server): the role is not tied to `rclone_restic_server`.

### Restoring in the cluster

K8up keeps a `Snapshot` resource for each snapshot in the namespace's repositories:

```sh
kubectl get snapshots -n app1
```

To put a claim's data back, stop the workload that uses it, so that nothing writes to the claim during the restore, then create a `Restore`:

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: restore-app-data
  namespace: app1
spec:
  backend:
    # The same as the Schedule's.
  # The latest snapshot of the claim. `snapshot: <id>` picks another.
  paths: [/data/app-data]
  restoreMethod:
    folder:
      claimName: app-data
  podSecurityContext:
    runAsUser: 0
```

The snapshot's files are written into the claim, over what is there. `delete: true` also removes files the snapshot does not have. Wait for it to finish, then start the workload again:

```sh
kubectl wait restore/restore-app-data -n app1 --for=condition=Completed --timeout=1h
```

A dump goes back through the database's own restore tool, with plain `restic` as below.

### Restoring with plain restic

Everything K8up writes is an ordinary restic snapshot, so plain `restic` restores it from any machine, with neither K8up nor the cluster. After losing the cluster, open the repository straight on the remote as [Restoring without the cluster](#restoring-without-the-cluster) describes:

```sh
export RESTIC_REPOSITORY=rclone:offsite:restic/app1/k8up
export RESTIC_PASSWORD=...           # the repository password

restic snapshots --host app1

# A claim's files, into ./restore/data/app-data
restic restore latest --host app1 --path /data/app-data --target ./restore

# A dump, straight into the database
restic dump latest --host app1 --path /app1-postgres.sql /app1-postgres.sql | psql -U postgres app
```

To take a snapshot out of the repository as a `.tar.gz`, of a claim or of a dump:

```sh
restic dump --archive tar --host app1 --path /data/app-data latest / | gzip > app-data.tar.gz
restic dump --archive tar --host app1 --path /app1-postgres.sql latest / | gzip > app1-postgres.tar.gz
```

The archive holds the snapshot's path: `data/app-data/...` for a claim, `app1-postgres.sql` for a dump. Give a snapshot ID in place of `--host`, `--path` and `latest` to take an older one.

## Certificates

`ptrampert.k8s.cert_manager` installs [cert-manager](https://cert-manager.io/), and two
`ClusterIssuer`s that issue publicly trusted certificates from Let's Encrypt over ACME:

| Issuer | Directory |
|---|---|
| `letsencrypt-staging` | Generous rate limits, untrusted certificates. Use it until issuance works. |
| `letsencrypt-production` | Trusted certificates, and Let's Encrypt's rate limits, including 5 duplicate certificates a week. |

cert-manager issues each certificate once, from one leader-elected controller, and stores it in a
Kubernetes Secret that any number of readers can use. That is what lets an ingress run several
replicas without each of them running its own ACME client and requesting the same certificate.

It installs the upstream Helm chart at the version `cert_manager_version` pins. The chart carries
the CRDs among its templates, so Helm upgrades them with the chart, and leaves them in place if the
release is uninstalled. Like `k8up`, the role installs the Python Kubernetes client from PyPI into a
venv under `/opt/cert-manager`.

### DNS-01

Both issuers prove control of a domain with DNS-01: cert-manager publishes a TXT record through the
DNS provider's API, and Let's Encrypt looks it up. Nothing has to reach the cluster from the
internet, and it is the only challenge that can issue wildcard certificates. HTTP-01 is not
offered.

`cert_manager_dns01` is the solver itself, exactly as cert-manager's `dns01` field takes it, so
every provider built into cert-manager works without anything from the role. Its credential goes in
`cert_manager_dns01_credential`, which the role stores as the Secret `cert-manager-dns01` in
`cert_manager_namespace`. The solver refers to it by that name. For example, with RFC 2136 dynamic
updates:

```yaml
cert_manager_dns01:
  rfc2136:
    nameserver: 192.0.2.53
    tsigKeyName: acme.example.com.
    tsigAlgorithm: HMACSHA256
    tsigSecretSecretRef:
      name: cert-manager-dns01
      key: tsig-secret
cert_manager_dns01_credential:
  tsig-secret: "{{ vault_acme_tsig_secret }}"
```

Providers that cert-manager reaches only through an external webhook need that webhook's own chart
installed first. The role does not install it.

The credential is the thing to protect. Anyone who can read it can get a certificate for any name
in the zone, so give it no more than edit rights on the zone's DNS records. It is kept in
`cert_manager_namespace`, and the role writes it there through the API server, never to a file on
the host. Like every Secret, it is stored unencrypted in etcd unless the cluster enables
encryption at rest.

### Requesting a certificate

The role creates no certificates. A `Certificate` belongs to whatever uses it, in the namespace its
Secret is meant for:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard
  namespace: ingress
spec:
  secretName: wildcard-tls
  dnsNames: ["*.example.com"]
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-production
```

The issuers are cluster-wide, so a `Certificate` in any namespace can use them, and the DNS
credential stays in one namespace. That suits a cluster running workloads at one level of trust.

Every certificate is published in public Certificate Transparency logs, permanently. A certificate
per host lists every host name, so one wildcard per domain level gives away less about what the
cluster runs.

## Example playbook

```yaml
- name: Prepare Kubernetes nodes
  hosts: k8s_cluster
  become: true
  roles:
    - ptrampert.k8s.node

# Whatever serves control_plane_endpoint comes first: see "The API server
# address" for a play that load balances on the control-plane nodes.

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

- name: Serve backup storage and back up to it
  hosts: control_plane[0]
  become: true
  roles:
    # Needs rclone_restic_server_config, _remote and _users.
    - ptrampert.k8s.rclone_restic_server
    # Installs the operator. Schedules belong to the workloads' playbooks.
    - ptrampert.k8s.k8up

- name: Issue certificates
  hosts: control_plane[0]
  become: true
  roles:
    # Needs cert_manager_dns01 and cert_manager_dns01_credential.
    - ptrampert.k8s.cert_manager
```

For a single-node cluster, put the host in `control_plane`, leave `workers` empty, and set `control_plane_schedulable: true`. It still needs a `control_plane_endpoint`; a DNS name pointing at the node lets it grow a second control-plane node later.

On hosts with more than one network interface, set `node_ip`, `control_plane_advertise_address`, and `control_plane_flannel_iface` so the cluster uses the intended network.
