# ptrampert Ansible collections

Ansible collections for building and running a small Kubernetes cluster on Ubuntu hosts, and the
general-purpose services around it.

| Collection | What it holds |
|---|---|
| [`ptrampert.k8s`](ptrampert/k8s/README.md) | Roles for a kubeadm-based cluster: node preparation (`node`), bootstrapping and growing the control plane (`control_plane`), joining workers (`worker`), and storage providers (`local_path_provisioner`, `nfs_provisioner`). |
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

List `ptrampert.general_services` even if you only use `ptrampert.k8s`. The k8s collection depends
on it, and `ansible-galaxy` only looks for dependencies on Galaxy, where it does not exist: without
the git entry the install fails with `Could not satisfy the following requirements:
ptrampert.general_services`. The other dependencies (`ansible.posix`, `kubernetes.core`) are on
Galaxy and are installed automatically.

`version` takes a branch, a tag or a commit. Pin a tag or a commit for installs that do not change
under you. Both collections live in one repository, so pinning one ref pins both.

## Versions and changes

Each collection has its own version in its `galaxy.yml` and its own `CHANGELOG.md`. Nothing is
published, but the version still matters: dependency constraints between the collections are
checked against it.

## Contributing

`AGENTS.md` describes the layout, the conventions roles follow, and how they are tested: on real
VMs with the Vagrant harnesses under `tests/`, which stand outside the collections so they are not
part of what gets installed. Issues and pull requests are on
[GitHub](https://github.com/PaulTrampert/ansible-collections).
