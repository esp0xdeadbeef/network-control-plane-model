# BUG: a cross-tenant service relation names the policy lane as egress while the route goes direct

Cross-tenant service discovery does not work, and the blocking hop is the downstream selector:
it receives the query, has a rule for the relation, and drops it -- because the rule's egress
interface is not the interface the route uses.

## Measured (neon HAT)

Requester: the clients resolver (`clients-dns`, on `access-clients`, fabric `10.10.0.0/31`).
Target: the unlock resolver (`unlock-dns`, on `access-unlock`, `10.3.90.1`, fabric
`10.10.0.12/31`). The relation is modelled and published:

```
services[unlock-dns].exposure.records = [ {
  relationId = "allow-clients-dns-to-unlock-dns";
  requesterScope = { kind = "service"; names = [ "clients-dns" ]; };
  ownerScope     = { kind = "service"; name = "unlock-dns"; };
  exposureClass  = "controlled";
} ];
services[unlock-dns].providerEndpoints = [ { name = "neon-unlock-dns";
                                             ipv4 = [ "10.3.90.1" ]; } ];
```

and the resolver config is correct at both ends -- `access-clients` has

```
forward-zone:
  forward-addr: 10.3.90.1
  name: unlock.home.arpa.
```

and `access-unlock` listens on `10.3.90.1:53` with
`ip daddr 10.3.90.1 udp dport 53 accept`.

The query leaves the requester and stops at the downstream selector:

```
tcpdump -i access-clients (on downstream-selector):
  10.10.0.0.40719 > 10.3.90.1.53: A? tang.unlock.home.arpa.
tcpdump -i policy-clients / -i policy-unlock / -i access-unlock: (nothing)
```

Its routing and its rules disagree:

```
downstream-selector # ip route get 10.3.90.1
10.3.90.1 via 10.10.0.12 dev access-unlock          <- direct to the access node

downstream-selector # nft list ruleset | grep allow-clients-dns-to-unlock-dns
iifname "access-clients" oifname "policy-clients" udp dport 53 accept ...
iifname "access-clients" oifname "policy-clients" tcp dport 53 accept ...
iifname "access-clients" oifname "policy-unlock"  udp dport 53 accept ...
iifname "access-clients" oifname "policy-unlock"  tcp dport 53 accept ...
iifname "policy-clients" oifname "access-clients" udp dport 53 ct state established,related accept ...
```

No rule covers `oifname "access-unlock"`, and the forward chain is `policy drop`, so the packet
is discarded without a reply (`dig` times out; the tenant sees `SERVFAIL` because its resolver
then fails the lookup).

## Why this is a producer issue

The transit rule is built from the relation's *target*, and the target is a service whose
endpoint sits on an access node. The egress interface on the transit node therefore depends on
where the endpoint is realized, which is a model fact (`providerEndpoints`), not on the policy
nodes that the relation also crosses. Publishing `oifname policy-clients` / `policy-unlock`
describes the path the policy node would take, not the path the selector actually takes.

Whoever fixes it: the transit rule for a relation must name the realized next hop for the
target endpoint on that target, i.e. `access-unlock` here -- or the route must send the flow
through policy first so that the published rule is the true one. Those two must agree; today
they do not.

## Consequence

`tang.unlock.home.arpa` never resolves from the clients tenant, which is the HAT's
cross-tenant proof:

```
tenant-client # dig tang.unlock.home.arpa @10.3.30.1     -> SERVFAIL
access-clients # dig tang.unlock.home.arpa @10.3.90.1   -> timeout
```
