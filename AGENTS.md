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

Available locally: `ansible-core` 2.21, `ansible-lint`, `yamllint`, `ansible-test`. Molecule is not installed.

```sh
# Lint a collection
cd ptrampert/k8s && ansible-lint

# Build the collection tarball
ansible-galaxy collection build ptrampert/k8s --output-path build/

# Install locally for use in playbooks
ansible-galaxy collection install build/ptrampert-k8s-*.tar.gz --force
```

`ansible-test` requires the collection to sit under a directory path ending in `ansible_collections/ptrampert/k8s`, which this repo layout doesn't provide on its own. To run it, clone or symlink the repo into such a path first (e.g. `~/ansible_collections/ptrampert -> <repo>/ptrampert`) and run it from there.

## Versioning

Each collection is versioned independently with semver via `version` in its `galaxy.yml`. Bump it when making changes intended for release.
