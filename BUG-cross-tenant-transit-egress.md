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

## Addendum: the selector's lane table sends the target address back to the requester

Looking one layer below the rule mismatch, the selector's own lookup for the real packet is
wrong before any filter runs:

```
downstream-selector # ip route get 10.3.90.1 from 10.10.0.0 iif access-clients
10.3.90.1 from 10.10.0.0 via 10.10.0.0 dev access-clients table 1001
    cache <redirect> iif access-clients

downstream-selector # ip route show table 1001 | head -6
10.3.30.0/24 via 10.10.0.0 dev access-clients proto static
10.3.30.1    via 10.10.0.0 dev access-clients proto static
10.3.60.1    via 10.10.0.0 dev access-clients proto static
10.3.90.1    via 10.10.0.0 dev access-clients proto static     <- the unlock resolver
10.10.0.0/31 dev access-clients proto static scope link
```

`10.3.90.1` is the unlock resolver, which lives on `access-unlock` (`10.10.0.12/31`), not on
`access-clients` (`10.10.0.0/31`). Table 1001 is the clients lane's table and it carries that
endpoint as if it were reached through the clients access node, so the packet is redirected
back to the port it arrived on.

So two independent layers hide the same flow:

1. the lane table points the target endpoint back at the requester's own lane, and
2. the relation's transit accepts name `policy-clients`/`policy-unlock`, an egress the route
   never uses.

Either one alone is enough to drop the query. They have to agree on the path, and the path has
to be the one the exposure contract names: `allow-clients-dns-to-unlock-dns` is `controlled`,
so the flow must cross the policy point, and therefore the selector's route for
`10.3.90.0/24` should point at the policy lane rather than at the access node.
