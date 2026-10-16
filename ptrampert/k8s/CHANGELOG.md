# Changelog

## Unreleased

- Add `node`, `control_plane`, and `worker` roles for bootstrapping a kubeadm cluster
  (single control plane, Flannel CNI).
- `control_plane` supports more than one control-plane node. A node joins by being added
  to the `control_plane` group; control-plane nodes join one at a time.
- `control_plane` gives every cluster a stable API server address, so a cluster that starts
  with one control-plane node can grow more later. `control_plane_endpoint` is required, and
  whatever serves it is set up by the playbook before the role runs; the README has a play
  that runs HAProxy and keepalived on the control-plane nodes themselves.
- `control_plane` no longer runs HAProxy and keepalived itself. `control_plane_load_balancer`,
  `control_plane_vip`, `control_plane_vip_prefix`, `control_plane_vip_interface`,
  `control_plane_vip_router_id`, `control_plane_lb_port` and `control_plane_lb_timeouts` are
  gone. To keep a cluster that used them, apply `ptrampert.general_services.haproxy` and
  `keepalived` in a play before `control_plane`, as in the README, with
  `control_plane_endpoint` set to the VIP and port (`<vip>:8443` for the old defaults). The
  collection no longer depends on `ptrampert.general_services`.
- Add a `local_path_provisioner` role: a `StorageClass` backed by a directory on each node,
  provisioned by Rancher's local-path-provisioner. The directory, the class name, the reclaim
  policy and whether the class is the cluster default are all configurable; the class is not
  the default unless asked.
- Add an `nfs_provisioner` role: a `StorageClass` backed by an NFS export that every node
  mounts, so a rescheduled pod keeps its data, provisioned by the kubernetes-csi NFS driver.
  The export is an input; the role does not build an NFS server, and the nodes need no NFS
  packages of their own.
- Add an `rclone_restic_server` role: `rclone serve restic` in the cluster behind a ClusterIP
  Service, storing restic repositories on any rclone remote. Users are required and each one
  reaches only its own repositories; append-only is an option. The rclone config seeds a copy
  on a volume, so OAuth tokens rclone refreshes survive restarts.
- Add a `k8up` role: the K8up backup operator, from the upstream Helm chart at a pinned
  version, for backing up volumes and the output of backup commands in annotated pods to
  restic repositories. The role applies the chart's CRDs itself, since Helm never upgrades
  them. It installs the operator only; backends, schedules and restores belong to the
  workloads.
- Add a `cert_manager` role: cert-manager from the upstream Helm chart at a pinned version, with
  `ClusterIssuer`s for Let's Encrypt's staging and production directories. Both solve DNS-01
  through the solver given in `cert_manager_dns01`, which takes any provider built into
  cert-manager, with the credential in `cert_manager_dns01_credential`. The role creates no
  certificates; they belong to whatever uses them.
