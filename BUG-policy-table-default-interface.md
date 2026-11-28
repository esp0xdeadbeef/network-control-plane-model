# BUG: a policy-table default is published on the lane that cannot carry its gateway

`FS-310-HDS-020-SDS-010-SMS-060` requires the renderer to install each canonical route into
exactly the table and lane the record names. For the per-tenant policy-table default, the
record names a lane whose link does not contain the gateway, so the kernel refuses the route.
The rule is installed, the table is empty, and the tenant is silently unreachable.

## Measured

Model: `nixos/prod-network/testing/intent-neon.nix` + `inventory-neon.nix`, target
`esp0xdeadbeef-neon-upstream-selector`, interface
`p2p-policy-upstream-selector--access-access-clients--uplink-wan` (renders as
`policy-clients`, address `10.10.0.49/31`, peer `10.10.0.48`).

The bundle publishes two defaults on that one interface:

```
{ dst = "0.0.0.0/0"; gateway = "10.10.0.49"; tableId = 1012;
  facts.reason = "policy-derived-default";
  facts.intent.kind = "default-reachability"; }

{ dst = "0.0.0.0/0"; gateway = "10.10.0.22"; tableId = 1004;
  facts.reason = "policy-table-default-reachability";
  facts.lane = { access = "access-clients"; kind = "access-uplink";
                 scope = "neon-clients"; uplink = "wan"; uplinks = [ "wan" ]; }; }
```

`10.10.0.22` is the **core** lane's peer (`p2p-core-upstream-selector` holds
`10.10.0.23/31`), not a neighbour on `policy-clients`. `10.10.0.49` is this interface's own
address, so the first record is not installable as a gateway route either.

Rendered and booted in the hardware acceptance fixture (the egress-chain HAT, neon site):

```
upstream-selector # ip -4 rule | grep 'iif policy-clients'
21004:  from all iif policy-clients lookup 1004 proto static

upstream-selector # ip route show table 1004 | grep '^default'
(no output)

upstream-selector # ip route get 1.1.1.1 from 10.3.30.100 iif policy-clients
RTNETLINK answers: Network is unreachable

tenant-client # traceroute -n 1.1.1.1
 1  10.3.30.1   0.089 ms
 2  10.10.0.1   0.106 ms
 3  10.10.0.27  0.143 ms
 4  10.10.0.49  0.127 ms !N
```

`/etc/systemd/network/10-policy-clients.network` does contain

```
[Route]
Destination=0.0.0.0/0
Gateway=10.10.0.22
GatewayOnLink=false
Metric=1000
Table=1004
```

and `systemd-networkd` refuses exactly that:

```
policy-clients: Failed to configure static route (dst: 0.0.0.0/0, gw: 10.10.0.22,
  table: 1004, flags: onlink? no): Nexthop has invalid gateway or device mismatch.
  Invalid argument
```

(the message is quoted from the sibling `cor-vpn-gar-neo` lane, which fails the same way:
`gw: fd42:dead:beef:1000::34:1 ... device mismatch`.)

## Why the renderer cannot repair it

* It may not invent `onlink`: the record says `GatewayOnLink = false`, and marking a
  two-hop gateway on-link makes the node ARP for an address that is not on that wire.
* It may not move the route to `core`: the record names `interface`, and the row forbids the
  renderer choosing a route's lane occurrence.
* It may not drop the route: that is "withhold", which the same sentence forbids, and it is
  the failure we already have.

So the placement itself has to change in the model: a policy-table default belongs on the
interface that owns its gateway (`p2p-core-upstream-selector` for `10.10.0.22`), or it must
carry the ingress lane's own peer (`10.10.0.48`) as its gateway. Which of the two is intended
is a model decision; `policy-lane-defaults.nix` currently appends the complement to the
`access-uplink` lane that triggered it (`complementInterface`), while
`defaultRouteFor` takes its `via` from the egress lane.

## Consequence today

Every tenant whose egress leaves through a lane other than the ingress lane has an installed
rule pointing at an empty table. On neon that is the clients tenant: DHCP works, DNS works,
and every packet is answered `Destination Net Unreachable` at hop 4.

## Related

`BUG-policy-return-occurrence.md` -- the same "record names a lane that is not the installing
lane" shape, for return routes.

## Addendum: after moving the complement, the lane default points back downstream

Fix `282e4a2` places the complement on the core interface, which is right. Rendering neon
again (renderer `9f5cf6a7`) shows the lane's table now holds a *different* record:

```
upstream-selector # ip route show table 1004 | grep '^default'
default via 10.10.0.48 dev policy-clients proto static
```

`10.10.0.48` is the peer on the *downstream* side of that lane (policy holds `10.10.0.48/31`,
the selector holds `10.10.0.49/31`). So the selector hands the tenant's packets straight back
to the policy node that forwarded them:

```
policy            # ip route get 1.1.1.1 from 10.3.30.100 iif down-clients
1.1.1.1 from 10.3.30.100 via 10.10.0.49 dev up-clients table 1012      -> selector
upstream-selector # ip route get 1.1.1.1 from 10.3.30.100 iif policy-clients
1.1.1.1 from 10.3.30.100 via 10.10.0.48 dev policy-clients table 1004  -> policy
```

and the tenant's traceroute dies at that hop (`10.10.0.55 ... *  *`), with no packet ever
reaching the core's `ppp0` (`tcpdump -i ppp0 icmp` counted zero).

That record comes from `policy-lane-defaults.nix` (`defaultRouteFor`), which builds a
complement whose gateway is `peerAddress` of the lane it is attached to. On a *policy* node
that peer is upstream and the route is correct; on an *upstream-selector* the same lane faces
downstream, so the peer is the way back. The complement needs the egress lane's peer in that
case -- which is exactly the route `282e4a2` now keeps on the core interface (`via
10.10.0.22`), and which the lane's table should point at.

Open: decide whether `policy-lane-defaults.nix` should skip lanes whose direction is
downstream on an upstream-selector (the role is a model fact), or whether the lane's table
should be populated from the core-side complement rather than from a peer-of-this-lane route.
