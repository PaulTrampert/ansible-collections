# AGENTS.md

This repository holds personal Ansible collections under the `ptrampert` namespace.

## Layout

Each collection lives at `<namespace>/<collection>/`, mirroring the `ansible_collections/<namespace>/<collection>` path Ansible expects.

```
ptrampert/
└── k8s/                  # ptrampert.k8s
    ├── galaxy.yml        # collection metadata (name, version, dependencies)
    ├── meta/runtime.yml  # requires_ansible, plugin routing
    ├── plugins/          # custom modules, filters, lookups, etc.
    ├── roles/            # roles (create as needed)
    └── README.md
tests/
└── k8s/                  # Vagrant test harness for ptrampert.k8s (see Testing)
```

### Collections

- **ptrampert.k8s** — roles for setting up and maintaining a Kubernetes cluster (node preparation, cluster bootstrap, upgrades, and ongoing maintenance).

When adding a new collection, scaffold it with `ansible-galaxy collection init ptrampert.<name>` from the repo root and add it to the list above.

## Working on roles

- Scaffold a new role with `ansible-galaxy role init --init-path ptrampert/k8s/roles <role_name>`, then delete any generated directories and files the role doesn't use.
- Role names use `snake_case` (collection roles cannot contain hyphens).
- Refer to roles by their fully qualified name, e.g. `ptrampert.k8s.<role_name>`.
- Use fully qualified module names everywhere (`ansible.builtin.copy`, not `copy`).
- Prefix every role variable with the role name (e.g. `<role_name>_version`) to avoid collisions between roles.
- Put user-tunable settings in `defaults/main.yml`; reserve `vars/main.yml` for internal constants.
- Document role inputs in `meta/argument_specs.yml` so they are validated at runtime.
- Tasks must be idempotent: a second run against an unchanged host should report no changes. Use `changed_when`/`creates` on `command`/`shell` tasks, and prefer purpose-built modules over shelling out.
- Restart or reload services through handlers rather than inline tasks.
- Name every task and play.
- If a role depends on another collection (e.g. `kubernetes.core`, `ansible.posix`), add it to `dependencies` in `galaxy.yml`.

## Tooling

Available locally: `ansible-core` 2.21, `ansible-lint`, `yamllint`, Vagrant 2.4 with the VirtualBox provider.

```sh
# Lint a collection
cd ptrampert/k8s && ansible-lint

# Build the collection tarball
ansible-galaxy collection build ptrampert/k8s --output-path build/

# Install locally for use in playbooks
ansible-galaxy collection install build/ptrampert-k8s-*.tar.gz --force
```

## Testing

Roles are tested with Vagrant: bring up real VMs, run the roles against them with a test playbook, and check the result. Containers and `ansible-test integration` aren't suitable here because cluster setup needs multiple nodes, systemd, kernel modules, and real networking. (`ansible-test sanity`/`units` only become relevant if Python plugins are added under `plugins/`.)

Test harnesses live outside the collection, under `tests/<collection>/` at the repo root (e.g. `tests/k8s/`), so they aren't included in the built collection tarball. Each harness contains:

- `Vagrantfile` — defines the test VMs (e.g. control plane and worker nodes) and their private network.
- `inventory` — static inventory for the VMs, grouped the way the roles expect.
- `playbook.yml` — applies the roles under test, referenced by FQCN (`ptrampert.k8s.<role_name>`).
- `ansible.cfg` — points `collections_path` at a directory where `ansible_collections/ptrampert` is a symlink to the repo's `ptrampert/`, so the playbook uses the working-tree roles without a build/install step.

Workflow:

```sh
cd tests/k8s
vagrant up                                # create VMs
ansible-playbook playbook.yml             # converge
ansible-playbook playbook.yml             # re-run: should report changed=0 (idempotence)
# verify: e.g. vagrant ssh <control-plane> -c 'kubectl get nodes'
vagrant destroy -f                        # tear down
```

`tests/k8s/` supports single-node and multi-node topologies; see `tests/k8s/README.md`.

Use `vagrant snapshot save`/`restore` to get back to a clean baseline quickly instead of rebuilding VMs between runs. A change to a role isn't done until it converges on fresh VMs and a second run reports no changes.

## Versioning

Each collection is versioned independently with semver via `version` in its `galaxy.yml`. Bump it when making changes intended for release.
