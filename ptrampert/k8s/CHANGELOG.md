# Changelog

## Unreleased

- Add `node`, `control_plane`, and `worker` roles for bootstrapping a kubeadm cluster
  (single control plane, Flannel CNI).
- `control_plane` supports more than one control-plane node. A node joins by being added
  to the `control_plane` group; control-plane nodes join one at a time.
- `control_plane` gives every cluster a stable API server address, so a cluster that starts
  with one control-plane node can grow more later. By default it runs HAProxy and keepalived
  on the control-plane nodes themselves and floats `control_plane_vip` between them; set
  `control_plane_load_balancer: external` with `control_plane_endpoint` to use a load
  balancer outside the cluster instead.
- Add an `nfs_provisioner` role: a `StorageClass` backed by an NFS export that every node
  mounts, so a rescheduled pod keeps its data, provisioned by the kubernetes-csi NFS driver.
  The export is an input; the role does not build an NFS server, and the nodes need no NFS
  packages of their own.
