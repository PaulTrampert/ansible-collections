# Ansible Collection - ptrampert.general_services

Roles for services that aren't tied to any one application. Supports Ubuntu.

## Roles

| Role | Purpose |
|---|---|
| `ptrampert.general_services.haproxy` | HAProxy, configured from a list of listeners. |
| `ptrampert.general_services.keepalived` | Virtual addresses that float between hosts over VRRP. |

Role inputs are documented in each role's `meta/argument_specs.yml`
(`ansible-doc -t role ptrampert.general_services.<role>`).

Together they make a service reachable at one address that survives losing a host: keepalived
elects which host holds the address, HAProxy balances what arrives there across the backends, and a
health check hands the address on when the local HAProxy stops working.

Neither role changes anything outside its own package, configuration file, and service — no
sysctls, no firewall rules, no other service's configuration. That is what lets them share a host
with the service they front instead of needing a dedicated load balancer, as long as HAProxy is
given a port that service isn't already using.

## Example

Two hosts sharing `192.0.2.10`, balancing HTTP across a pool of web servers. Per-host
`vrrp_priority` (highest wins) comes from the inventory:

```yaml
- name: Load balance the web tier
  hosts: load_balancers
  become: true
  vars:
    haproxy_listen:
      - name: web
        bind: "*:80"
        mode: http
        balance: roundrobin
        options: [httplog, forwardfor]
        server_options: "check inter 2s fall 2 rise 2"
        servers:
          - {name: web1, address: "192.0.2.21:8080"}
          - {name: web2, address: "192.0.2.22:8080"}

    keepalived_scripts:
      chk_haproxy:
        command: "/bin/bash -c '</dev/tcp/127.0.0.1/80'"
        interval: 2
        fall: 2
        rise: 2

    keepalived_vrrp_instances:
      - name: web
        interface: eth1
        virtual_router_id: 60
        priority: "{{ vrrp_priority }}"
        virtual_ipaddresses: ["192.0.2.10/24"]
        track_scripts: [chk_haproxy]
  roles:
    - ptrampert.general_services.haproxy
    - ptrampert.general_services.keepalived
```

A few things worth knowing:

- **The health check decides who holds the address.** A `track_script` with no `weight` puts its
  instance into the `FAULT` state when it fails, so the host releases the address. Checking the
  frontend port (as above) catches an HAProxy that has died or stopped listening; checking
  `systemctl is-active haproxy` would not.
- **Track scripts run as an unprivileged user** (`keepalived_script_user`, created by the role)
  with script security on, so the check must be something an ordinary user can do. The bash
  redirect above needs no extra package; `pkill -0 haproxy` would fail, because the check cannot
  signal a root-owned process.
- **`virtual_router_id` must be unique** among the VRRP instances on the same network.
- **More than one service can float an address from the same host.** Apply `keepalived` once per
  service, each time with its own `keepalived_config_name`: each name keeps its own instances and
  scripts, and the role assembles all of them into one configuration. The global settings
  (`keepalived_router_id`, `keepalived_script_user` and the like) are shared, so give them the
  same values each time.
- **Nothing opens the firewall.** VRRP (IP protocol 112) between the hosts, and the frontend port,
  have to be allowed however the network is managed.
- **Server lists can follow an inventory group** instead of being written out, which is useful when
  the backends are the hosts of a group:

  ```yaml
  haproxy_backend:
    name: "{{ inventory_hostname }}"
    address: "{{ ansible_host }}:8080"
  # ...
    servers: >-
      {{ groups['web'] | map('extract', hostvars)
         | map(attribute='haproxy_backend') | list }}
  ```

The `haproxy` role writes `listen` sections only; it has no separate `frontend`/`backend`
splitting, so HTTP content switching across several backend pools isn't expressible yet.

## On a Kubernetes control-plane node

These roles can serve the API server address of a kubeadm cluster with more than one control-plane
node, running on the control-plane nodes themselves. `ptrampert.k8s.control_plane` takes that
address as `control_plane_endpoint` and doesn't set up the load balancing itself. The
[ptrampert.k8s README](../k8s/README.md#load-balancing-on-the-control-plane-nodes) has the
complete play.

The one rule particular to running there: **give HAProxy a port of its own.** `kube-apiserver`
already has 6443 on every control-plane node, so HAProxy listens on another port, such as 8443, and
balances to 6443 on each node.
