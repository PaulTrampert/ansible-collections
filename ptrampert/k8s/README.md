# Ansible Collection - ptrampert.k8s

Roles for building and maintaining kubeadm-based Kubernetes clusters on Ubuntu.

## Roles

| Role | Runs on | Purpose |
|---|---|---|
| `ptrampert.k8s.node` | every node | Kubernetes host prerequisites: swap off, kernel modules and sysctls, containerd (pinned to a release series), kubelet/kubeadm/kubectl (held at a fixed version), kubelet node IP. |
| `ptrampert.k8s.control_plane` | first host in `control_plane` | `kubeadm init` from a templated config, kubeconfigs for users, Helm, Flannel CNI, and the control-plane scheduling toggle. |
| `ptrampert.k8s.worker` | `workers` | `kubeadm join` with a short-lived token, then waits for the node to become Ready. |

Role inputs are documented in each role's `meta/argument_specs.yml` (`ansible-doc -t role ptrampert.k8s.<role>`).

Not supported yet: additional control-plane nodes (HA), Kubernetes version upgrades.

## Inventory

The roles expect these groups:

- `control_plane`: control-plane nodes (currently exactly one).
- `workers`: worker nodes (may be empty for a single-node cluster).
- A parent group containing both, used to run `ptrampert.k8s.node` (e.g. `k8s_cluster`).

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

For a single-node cluster, put the host in `control_plane`, leave `workers` empty, and set `control_plane_schedulable: true`.

On hosts with more than one network interface, set `node_ip`, `control_plane_advertise_address`, and `control_plane_flannel_iface` so the cluster uses the intended network.
