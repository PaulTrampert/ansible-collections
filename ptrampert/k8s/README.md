# Ansible Collection - ptrampert.k8s

Roles for building and maintaining kubeadm-based Kubernetes clusters on Ubuntu.

## Roles

| Role | Runs on | Purpose |
|---|---|---|
| `ptrampert.k8s.node` | every node | Kubernetes host prerequisites: swap off, kernel modules and sysctls, containerd (pinned to a release series), kubelet/kubeadm/kubectl (held at a fixed version), kubelet node IP. |
| `ptrampert.k8s.control_plane` | `control_plane` | A stable API server address, `kubeadm init` on the first node and `kubeadm join` on the rest, kubeconfigs for users, Helm, Flannel CNI, and the scheduling toggle. |
| `ptrampert.k8s.worker` | `workers` | `kubeadm join` with a short-lived token, then waits for the node to become Ready. |

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
```

For a single-node cluster, put the host in `control_plane`, leave `workers` empty, and set `control_plane_schedulable: true`. It still gets a VIP, so it can grow a second control-plane node later.

On hosts with more than one network interface, set `node_ip`, `control_plane_advertise_address`, and `control_plane_flannel_iface` so the cluster uses the intended network. The VIP follows `control_plane_advertise_address` unless `control_plane_vip_interface` says otherwise.
