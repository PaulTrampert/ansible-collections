# ptrampert.general_services test harness

Vagrant VMs (VirtualBox, `bento/ubuntu-24.04`) for converging the collection's roles on real hosts.

Two load balancers, `lb1` (192.168.56.20) and `lb2` (192.168.56.21), share the VIP
**192.168.56.30** on the private network `eth1`. `eth0` is VirtualBox NAT and has the same address
on every VM, so `inventory/lb.yml` points the VIP and the backends at `eth1`.

`playbook.yml` first installs a backend for HAProxy to balance across — a static page naming the
host that served it, on port 8080 — then applies `haproxy` (a `mode: http` listener on port 80) and
`keepalived` (the VIP, released by whichever host loses its HAProxy). `lb1` has the higher VRRP
priority, so it holds the VIP whenever it is healthy.

```sh
vagrant up
ansible-playbook playbook.yml     # converge
ansible-playbook playbook.yml     # must report changed=0
ansible-playbook verify.yml       # VIP up on one host, balancing across both backends
ansible-playbook failover.yml     # VIP moves when HAProxy dies, and comes back
vagrant destroy -f
```

`verify.yml` is read-only. `failover.yml` stops HAProxy on whichever host holds the VIP, so run it
deliberately; it starts HAProxy again and waits for the VIP to return before finishing.

To get back to a clean baseline without rebuilding, take a snapshot right after `vagrant up`
(`vagrant snapshot save fresh`) and restore it before each run (`vagrant snapshot restore fresh`).

The IPs don't overlap `tests/k8s/`, so both harnesses can be up at once.
