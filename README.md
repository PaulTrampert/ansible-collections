# ptrampert Ansible collections

Ansible collections for building and running a small Kubernetes cluster on Ubuntu hosts, and the
general-purpose services around it.

| Collection | What it holds |
|---|---|
| [`ptrampert.k8s`](ptrampert/k8s/README.md) | Roles for a kubeadm-based cluster: node preparation (`node`), bootstrapping and growing the control plane (`control_plane`), joining workers (`worker`), storage providers (`local_path_provisioner`, `nfs_provisioner`), backup storage for restic (`rclone_restic_server`), the K8up backup operator (`k8up`), and cert-manager with Let's Encrypt issuers (`cert_manager`). |
| [`ptrampert.general_services`](ptrampert/general_services/README.md) | Roles for services that aren't tied to any one application: `haproxy` and `keepalived`. |

Each collection's README covers how its roles fit together, and each role documents its inputs in
`meta/argument_specs.yml` (`ansible-doc -t role ptrampert.<collection>.<role>`).

Requires `ansible-core` 2.16 or later.

## Installing

The collections are not published to Ansible Galaxy. Install them straight from this repository
with `ansible-galaxy`, which checks out the repository and picks a collection out of it by path:

```yaml
# requirements.yml
collections:
  - name: git+https://github.com/PaulTrampert/ansible-collections.git#/ptrampert/k8s
    type: git
    version: main
  - name: git+https://github.com/PaulTrampert/ansible-collections.git#/ptrampert/general_services
    type: git
    version: main
```

```sh
ansible-galaxy collection install -r requirements.yml
```

The collections don't depend on each other: `ptrampert.k8s` roles never apply `haproxy` or
`keepalived` themselves, so list `ptrampert.general_services` only if your playbooks use it, for
example to load balance the API server (see the k8s README). The other dependencies
(`ansible.posix`, `kubernetes.core`) are on Galaxy and are installed automatically.

`version` takes a branch, a tag or a commit. Pin a tag or a commit for installs that do not change
under you. Both collections live in one repository, so pinning one ref pins both.

## Versions and changes

Each collection has its own version in its `galaxy.yml` and its own `CHANGELOG.md`. Nothing is
published, but the version still says what changed between two refs.

The roles pin the upstream software they install. Renovate proposes newer releases weekly, one
pull request per collection, and each one raises that collection's patch version. They are
tested before merging like any other change.

## Contributing

`AGENTS.md` describes the layout, the conventions roles follow, and how they are tested: on real
VMs with the Vagrant harnesses under `tests/`, which stand outside the collections so they are not
part of what gets installed. Issues and pull requests are on
[GitHub](https://github.com/PaulTrampert/ansible-collections).
