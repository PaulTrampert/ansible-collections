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
| `.9` | the API server VIP, floated between the control-plane nodes — no VM has it |
| `.10`–`.12` | `cp1`–`cp3` |
| `.21`–`.22` | `worker1`–`worker2` |
| `.30` | `nfs1`, which exports `/srv/nfs` to the private network |

Set `K8S_TOPOLOGY` for **every** `vagrant` command, including `destroy` — without it Vagrant doesn't know the other VMs exist. Destroy one topology before bringing up another: they share VM names.

## Running a topology

```sh
export K8S_TOPOLOGY=stacked-ha
vagrant up
ansible-playbook -i inventory/stacked-ha.yml playbook.yml   # converge
ansible-playbook -i inventory/stacked-ha.yml playbook.yml   # must report changed=0
ansible-playbook -i inventory/stacked-ha.yml verify.yml
vagrant destroy -f
```

`single` needs no `-i`; it is the default in `ansible.cfg`.

To get back to a clean baseline without rebuilding, take a snapshot right after `vagrant up` (`vagrant snapshot save fresh`) and restore it before each run (`vagrant snapshot restore fresh`).

## What the playbooks check

`verify.yml` checks that the cluster was built with the address the inventory asked for, that every inventory host is a Ready node, that every control-plane host joined as one and runs an etcd member, that the system pods are Ready, and that in-cluster DNS resolves. Everything goes through the load balancer, because the kubeconfig points at it. On the stacked topologies it also checks that exactly one node holds the VIP and that *every* control-plane node's HAProxy serves the API, not only the one currently holding it. On `multi` it also checks the NFS storage provider: that the class is provisioned by the NFS CSI driver, that a pod on one worker reads back what a pod on the other worker wrote to the same volume, and that the volume really is a directory on `nfs1`'s export. It removes what it created afterwards, so it can be run again.

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

## Adding a control-plane node

The point of `stacked-ha` is that a node joins by appearing in the inventory. To see it, bring the topology up and converge with only `cp1` and `cp2` in `inventory/stacked-ha.yml`, then put `cp3` back and converge again — `cp1` and `cp2` report no changes and `cp3` joins.

The same works from `single`: `cp1` alone gets a VIP, so the cluster it creates can grow. Bring up `stacked-ha` (which includes `cp1` at the same address), converge with `inventory/single-node.yml`, then converge again with `inventory/stacked-ha.yml`.
