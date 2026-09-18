# ptrampert.k8s test harness

Vagrant VMs (VirtualBox, `bento/ubuntu-24.04`) for converging the collection's roles on real hosts.

| Topology | VMs | Inventory |
|---|---|---|
| `single` (default) | `cp1` (control plane, schedulable) | `inventory/single-node.yml` (the default in `ansible.cfg`) |
| `multi` | `cp1`, `worker1`, `worker2` | `inventory/multi-node.yml` |

The VMs use the private network `192.168.56.0/24` on `eth1`. `eth0` is VirtualBox NAT and has the same address on every VM, so the inventories point the kubelet, API server, and Flannel at `eth1`.

## Single node

```sh
vagrant up
ansible-playbook playbook.yml    # converge
ansible-playbook playbook.yml    # must report changed=0
ansible-playbook verify.yml      # nodes Ready, system pods Ready, in-cluster DNS works
vagrant ssh cp1 -c 'kubectl get nodes'
vagrant destroy -f
```

## Multi node

Set `K8S_TOPOLOGY=multi` for **every** `vagrant` command, including `destroy`. Without it, Vagrant doesn't know the worker VMs exist.

```sh
export K8S_TOPOLOGY=multi
vagrant up
ansible-playbook -i inventory/multi-node.yml playbook.yml
ansible-playbook -i inventory/multi-node.yml playbook.yml
ansible-playbook -i inventory/multi-node.yml verify.yml
vagrant destroy -f
```

To get back to a clean baseline without rebuilding, take a snapshot right after `vagrant up` (`vagrant snapshot save fresh`) and restore it before each run (`vagrant snapshot restore fresh`).
