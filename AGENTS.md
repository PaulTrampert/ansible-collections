# AGENTS.md

This repository holds personal Ansible collections under the `ptrampert` namespace.

## Layout

Each collection lives at `<namespace>/<collection>/`, mirroring the `ansible_collections/<namespace>/<collection>` path Ansible expects.

```
ptrampert/
├── k8s/                  # ptrampert.k8s
│   ├── galaxy.yml        # collection metadata (name, version, dependencies)
│   ├── meta/runtime.yml  # requires_ansible, plugin routing
│   ├── plugins/          # custom modules, filters, lookups, etc.
│   ├── roles/            # roles (create as needed)
│   └── README.md
└── general_services/     # ptrampert.general_services (same layout)
tests/
├── k8s/                  # Vagrant test harness for ptrampert.k8s (see Testing)
└── general_services/     # Vagrant test harness for ptrampert.general_services
.github/
├── renovate.json5        # Renovate configuration (see Dependency updates)
├── renovate/             # Renovate's global config and post-upgrade script
└── workflows/renovate.yml
```

### Collections

- **ptrampert.k8s** — roles for setting up and maintaining a Kubernetes cluster (node preparation, cluster bootstrap, upgrades, and ongoing maintenance).
- **ptrampert.general_services** — roles for services that aren't tied to any one application (HAProxy load balancing, keepalived VIPs).

When adding a new collection, scaffold it with `ansible-galaxy collection init ptrampert.<name>` from the repo root, and add it to the list above and to the top-level `README.md`. Also give it a `packageRules` entry in `.github/renovate.json5` like the existing collections have, so its updates are grouped and bump its version.

## Working on roles

- Scaffold a new role with `ansible-galaxy role init --init-path ptrampert/<collection>/roles <role_name>`, then delete any generated directories and files the role doesn't use.
- Role names use `snake_case` (collection roles cannot contain hyphens).
- Refer to roles by their fully qualified name, e.g. `ptrampert.k8s.<role_name>`.
- Use fully qualified module names everywhere (`ansible.builtin.copy`, not `copy`).
- Prefix every role variable with the role name (e.g. `<role_name>_version`) to avoid collisions between roles.
- Put user-tunable settings in `defaults/main.yml`; reserve `vars/main.yml` for internal constants.
- Document role inputs in `meta/argument_specs.yml` so they are validated at runtime.
- Tasks must be idempotent: a second run against an unchanged host should report no changes. Use `changed_when`/`creates` on `command`/`shell` tasks, and prefer purpose-built modules over shelling out.
- Restart or reload services through handlers rather than inline tasks.
- Name every task and play.
- Annotate every pinned upstream version with a `# renovate:` comment, in `defaults/main.yml` and above its `default:` in `meta/argument_specs.yml` (see Dependency updates).
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

Harness runs take a long time: bringing up a topology, converging it twice and verifying it can take an hour or more. While anything from this repository is running, report its status every 10 minutes without being asked: the topology and step it is on, what has finished and with what result, and which VMs are up. Waiting for the run to finish, or for someone to ask, isn't enough.

For a clean baseline, destroy the VMs and bring them up again (`vagrant destroy -f && vagrant up`) rather than restoring a `vagrant snapshot`: a restored VM can come back unreachable over SSH until it is rebooted, and only a new VM is fresh. A change to a role isn't done until it converges on fresh VMs and a second run reports no changes.

## Documentation

The top-level `README.md` is written for people using the collections: what each one contains and how to install them from git. Keep it up to date in every pull request: a PR that adds, renames or removes a collection or a role, changes a collection's dependencies, or changes how the collections are installed updates `README.md` in the same PR. The same applies to each collection's own `README.md` and `CHANGELOG.md`.

## Versioning

Each collection is versioned independently with semver via `version` in its `galaxy.yml`. Bump it when making changes intended for release.

## Dependency updates

Renovate keeps the pinned upstream versions current. It runs from `.github/workflows/renovate.yml` every Monday, or on demand from the Actions tab, and opens at most one PR per collection covering every pin in it with a newer release. Each PR bumps that collection's PATCH version and adds a `CHANGELOG.md` section. Nothing is merged automatically: test a Renovate PR on the Vagrant harness like any other change, and raise the bump to MINOR or MAJOR if consuming the update needs changes downstream.

Renovate finds a pin by the annotation on the line above it, so every new version pin needs one, both in `defaults/main.yml` and above its `default:` in `meta/argument_specs.yml`:

```yaml
# renovate: datasource=docker depName=rclone/rclone
rclone_restic_server_version: "1.75.2"
```

The fields, in this order, are `datasource` (where releases are looked up: `docker`, `github-releases`, `github-tags`, `helm`, `pypi`, ...), `depName` (the image, repository, chart or package), then optionally `registryUrl` (e.g. a Helm chart repository) and `versioning` (when the datasource's default scheme doesn't fit). The value must be on the next line, as `<name>: <version>`, quoted or not.

A pin that needs more than the annotation gets a `packageRules` entry in `.github/renovate.json5` too, matched on its `datasource` and `depName`. `node_kubernetes_version` has one, holding it to one minor version at a time because kubeadm can't upgrade further in one step, and `node_containerd_series` has one, cutting the apt package's versions down to its release series.

Renovate can't tie one pin to another, so a few move by hand in the PR that moves Kubernetes to a new minor version, as its description says: the cap on the Python Kubernetes client (`allowedVersions` in `.github/renovate.json5`), whose major version follows the Kubernetes minor, with the `*_kubernetes_client_version` pins, and `node_sandbox_image`.

## Pull requests

When addressing review comments, make one commit per comment, unless a single logical change addresses several comments, in which case that change is one commit. Cite the commit in the reply to each comment it addresses.
