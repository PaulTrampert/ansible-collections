# ptrampert.general_services test harness

Vagrant VMs (VirtualBox, `bento/ubuntu-24.04`) for converging the collection's roles on real hosts.

Two load balancers, `lb1` (192.168.56.20) and `lb2` (192.168.56.21), share the VIP
**192.168.56.30** on the private network `eth1`. `eth0` is VirtualBox NAT and has the same address
on every VM, so `inventory/lb.yml` points the VIP and the backends at `eth1`.

`playbook.yml` first installs a backend for HAProxy to balance across — a static page naming the
host that served it, on port 8080 — then applies `haproxy` (a `mode: http` listener on port 80) and
`keepalived` (the VIP, released by whichever host loses its HAProxy). `lb1` has the higher VRRP
priority, so it holds the VIP whenever it is healthy.

It then applies `keepalived` a second time, under `keepalived_config_name: backend`, to float a
second VIP, **192.168.56.31**, straight onto the backends. That checks that two services' VRRP
instances can share a host without one application replacing the other's.

```sh
vagrant up
ansible-playbook playbook.yml     # converge
ansible-playbook playbook.yml     # must report changed=0
ansible-playbook verify.yml       # each VIP up on one host, balancing across both backends
ansible-playbook failover.yml     # each VIP moves when its service dies, and comes back
vagrant destroy -f
```

`verify.yml` is read-only. Give keepalived a few seconds after the first converge to elect a
holder before running it. `failover.yml` stops HAProxy on whichever host holds the web VIP, then
the backend on whichever holds the backend VIP, checking that the web VIP stays where it is the
second time. Run it deliberately; it starts each service again and waits for its VIP to return
before finishing.

To get back to a clean baseline without rebuilding, take a snapshot right after `vagrant up`
(`vagrant snapshot save fresh`) and restore it before each run (`vagrant snapshot restore fresh`).

Some of the IPs are also used by `tests/k8s/` (`worker1` is .21 and `nfs1` is .30), so don't bring
both harnesses up at once.
