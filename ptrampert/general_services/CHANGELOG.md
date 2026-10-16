# Changelog

## Unreleased

- Add `haproxy` and `keepalived` roles for load balancing a service behind a floating VIP.
- `keepalived` can be applied more than once to the same host, for different services: each
  application names itself with `keepalived_config_name` and keeps its own VRRP instances and
  scripts, which the role assembles into one configuration.
