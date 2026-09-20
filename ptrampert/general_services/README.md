# Ansible Collection - ptrampert.general_services

Roles for services that aren't tied to any one application. Supports Ubuntu.

## Roles

| Role | Purpose |
|---|---|
| `ptrampert.general_services.haproxy` | HAProxy load balancer, configured from a list of listeners. |
| `ptrampert.general_services.keepalived` | Floating VIPs via VRRP, with optional health-check scripts. |

Role inputs are documented in each role's `meta/argument_specs.yml`
(`ansible-doc -t role ptrampert.general_services.<role>`).
