# ptrampert.k8s test harness

Vagrant VMs (VirtualBox, `bento/ubuntu-24.04`) for converging the collection's roles on real hosts.

| `K8S_TOPOLOGY` | VMs | Inventory | RAM |
|---|---|---|---|
| `single` (default) | `cp1` (schedulable) | `inventory/single-node.yml` (the default in `ansible.cfg`) | 4G |
| `multi` | `cp1`, `worker1`, `worker2`, `nfs1` | `inventory/multi-node.yml` | 13G |
| `stacked-ha` | `cp1`, `cp2`, `cp3` (schedulable) | `inventory/stacked-ha.yml` | 12G |
| `external-lb` | `lb1`, `cp1`, `cp2`, `cp3`, `worker1` | `inventory/external-lb.yml` | 17G |

Addresses on the private network `192.168.56.0/24`, which the VMs reach on `eth1`. `eth0` is VirtualBox NAT and has the same address on every VM, so `inventory/group_vars/all.yml` points the kubelet, API server, Flannel, and keepalived at `eth1`.

| | |
|---|---|
| `.8` | `lb1` |
| `.9` | the API server VIP, floated between the control-plane nodes in every topology but `external-lb` — no VM has it |
| `.10`–`.12` | `cp1`–`cp3` |
| `.21`–`.22` | `worker1`–`worker2` |
| `.30` | `nfs1`, which exports `/srv/nfs` to the private network |

Set `K8S_TOPOLOGY` for **every** `vagrant` command, including `destroy` — without it Vagrant doesn't know the other VMs exist. Destroy one topology before bringing up another: they share VM names.

## The API server's load balancer

`ptrampert.k8s.control_plane` only takes the API server's address, so `playbook.yml` sets up what serves it before the control plane, the way a real playbook would. In `single`, `multi` and `stacked-ha`, the control-plane nodes are in the `control_plane_lb` group. That play runs `ptrampert.general_services.haproxy` on port 8443 on each of them, balancing across every API server, and `ptrampert.general_services.keepalived` to float the VIP between them. In `external-lb` that group is empty, and `lb1`, in `load_balancers`, runs HAProxy on 6443 instead.

## Running a topology

```sh
export K8S_TOPOLOGY=stacked-ha
vagrant up
ansible-playbook -i inventory/stacked-ha.yml playbook.yml   # converge
ansible-playbook -i inventory/stacked-ha.yml playbook.yml   # must report changed=0
ansible-playbook -i inventory/stacked-ha.yml verify.yml
ansible-playbook -i inventory/stacked-ha.yml playbook.yml   # still changed=0 after verify.yml changed the restic server's config copy
vagrant destroy -f
```

`single` needs no `-i`; it is the default in `ansible.cfg`.

To get back to a clean baseline without rebuilding, take a snapshot right after `vagrant up` (`vagrant snapshot save fresh`) and restore it before each run (`vagrant snapshot restore fresh`).

## What the playbooks check

`verify.yml` checks that the cluster was built with the address the inventory asked for, that every inventory host is a Ready node, that every control-plane host joined as one and runs an etcd member, that the system pods are Ready, and that in-cluster DNS resolves. Everything goes through the load balancer, because the kubeconfig points at it. On the stacked topologies it also checks that exactly one node holds the VIP and that *every* control-plane node's HAProxy serves the API, not only the one currently holding it.

It then checks storage. On every topology: that the local-path `StorageClass` is the cluster default, that a claim naming no class binds, and that a second pod reads back what the first one wrote to the volume. On `multi` also the NFS provider: that its class is provisioned by the NFS CSI driver, that a pod on one worker reads back what a pod on the other worker wrote to the same volume, and that the volume really is a directory on `nfs1`'s export. It removes what it created afterwards, so it can be run again.

Then the restic REST server, with restic in throwaway pods against its Service: that `init`, a backup, `check --read-data` and a restore matching the source succeed; that a request without credentials gets 401 and one for another user's repository 403; that a copy of the config changed on the volume survives killing the pod, and the replacement serves both backups taken so far. Then, on the host, with restic's `rclone:` backend straight on the remote and no server: that `restic dump --archive tar` of the latest snapshot matches the source, and that a backup and a prune run there are what the server shows afterwards. Finally, through the append-only instance, that `forget --prune` fails and a backup still succeeds. It deletes the repositories at the start, so it can be run again.

Last, K8up: that the operator is running and that the role, not Helm, applied its CRDs. Then, in a throwaway namespace, a pod filling a node-local claim, one filling an NFS claim on `multi`, and a stand-in database whose backup command is in its annotations. A `Schedule` backs the namespace up through the restic server's `rest` backend, as the `k8up` user, and is deleted once its first backup has succeeded. On the host, plain `restic` straight on the remote checks there is a snapshot of every claim and of the dump, that `restic dump --archive tar` of each matches the source, and that `restic restore` gives back the dump. Then it deletes the data in the claims, restores each with a `Restore`, and checks the claims hold what was written to them. It deletes the namespace afterwards and the repository at the start, so it can be run again.

Then cert-manager: that its deployments are rolled out, its CRDs established, and both `ClusterIssuer`s Ready, which means each has registered an ACME account with its Let's Encrypt directory. With a real DNS provider in `cert-manager-dns.yml` (below), it also requests a wildcard certificate from the staging issuer in a throwaway namespace, waits for it to be issued, and checks its Secret is a `kubernetes.io/tls` Secret for that wildcard. Without one, it says so and skips that part.

`failover.yml` (stacked topologies only, destructive but self-restoring) stops HAProxy on the node holding the VIP, checks the VIP moves to another node and the API keeps answering, then starts HAProxy again and checks the VIP comes back.

```sh
ansible-playbook -i inventory/stacked-ha.yml failover.yml
```

## The NFS server

Only `multi` has one. `nfs1` is an ordinary Ubuntu VM that `playbook.yml` installs
`nfs-kernel-server` on and exports `/srv/nfs` from, with `no_root_squash` because the CSI driver
creates each volume's directory as root. It is a test export, not a model for a real one, and it
stands outside the collection on purpose: `ptrampert.k8s.nfs_provisioner` consumes an export
rather than building one.

The other topologies declare an empty `nfs_servers` group, and both the export play and the
provisioner are skipped there.

## The restic server's remote

`playbook.yml` creates a `restic-store` user on the first control-plane node, and both instances of `ptrampert.k8s.rclone_restic_server` store the repositories there over SFTP, under `/srv/restic-store/repos`. The second instance, in the `rclone-restic-append-only` namespace, serves the same repositories append-only. The `k8up` user holds the repository `verify.yml` backs up to with K8up. The credentials and the users' bcrypt hashes in `inventory/group_vars/all.yml` are test values for throwaway VMs.

## Issuing a real certificate

The VMs have no public domain, so by default `inventory/group_vars/all.yml` gives cert-manager a solver that is never used: an RFC 2136 server at a documentation address. The issuers become Ready without it, because registering an ACME account needs no DNS.

To check issuance end to end, create `cert-manager-dns.yml` next to `playbook.yml`. It is gitignored, since it holds a real credential. Both `playbook.yml` and `verify.yml` read it when it exists, and its values override the placeholder:

```yaml
# A domain the credential can create TXT records in. verify.yml requests *.<domain>.
verify_cert_manager_domain: example.com
# The solver and credential, as ptrampert.k8s.cert_manager takes them.
cert_manager_dns01:
  rfc2136:
    nameserver: 192.0.2.53
    tsigKeyName: acme.example.com.
    tsigAlgorithm: HMACSHA256
    tsigSecretSecretRef:
      name: cert-manager-dns01
      key: tsig-secret
cert_manager_dns01_credential:
  tsig-secret: <base64 TSIG secret>
```

Then converge and run `verify.yml` as usual. The certificate comes from the staging directory, so it costs nothing against production's rate limits. Like every certificate, it is published in Certificate Transparency logs.

## Adding a control-plane node

The point of `stacked-ha` is that a node joins by appearing in the inventory. To see it, bring the topology up and converge with only `cp1` and `cp2` in `inventory/stacked-ha.yml`, then put `cp3` back and converge again — `cp1` and `cp2` report no changes and `cp3` joins.

The same works from `single`: `cp1` alone gets a VIP, so the cluster it creates can grow. Bring up `stacked-ha` (which includes `cp1` at the same address), converge with `inventory/single-node.yml`, then converge again with `inventory/stacked-ha.yml`.
