{ lib }:

# FS-470 (Remote Egress over WireGuard) + FS-470-HDS-010-SDS-010: a node that
# advertises, or answers for, a tenant or protected prefix declares that
# advertisement as explicit intent on the node. The forwarding and
# control-plane models emit that reachability only when the declaration is
# present; it is never inferred from the node's underlay attachment, overlay
# membership, or NAT source set.
#
# The compiler resolves the intent declaration to concrete prefixes and the
# forwarding model carries them through unchanged, so this module consumes
# `target.advertises` as-is. It installs one return route per advertised IPv4
# prefix on every fabric point-to-point interface, addressed to the interface
# peer, so the fabric can return tenant/protected traffic to the advertising
# node.
rtAttrs:
lib.mapAttrs (
  targetName: target:
  let
    advertisedPrefixes4 = lib.filter (
      prefix: builtins.isString prefix && !(lib.hasInfix ":" prefix)
    ) (target.advertises or [ ]);
    role = target.role or "";
    isCore = builtins.substring 0 4 role == "core";
    interfaces = (target.effectiveRuntimeRealization or { }).interfaces or { };
    isFabricP2p =
      iface:
      (iface.sourceKind or "") == "p2p"
      && ((iface.backingRef or { }).lane or { }).uplink or "" != "wan";
    peer4For =
      addr:
      let
        parts = lib.splitString "/" addr;
        addrStr = if builtins.length parts >= 1 then builtins.elemAt parts 0 else "";
        octets = lib.splitString "." addrStr;
      in
      if builtins.length octets != 4 then
        null
      else
        let
          lastOctet = builtins.elemAt octets 3;
          lastInt = lib.toInt (if lastOctet == "" then "0" else lastOctet);
          peerInt = if lib.mod lastInt 2 == 0 then lastInt + 1 else lastInt - 1;
          peerOctets = builtins.genList (
            i: if i == 3 then builtins.toString peerInt else builtins.elemAt octets i
          ) 4;
        in
        builtins.concatStringsSep "." peerOctets;
  in
  if !isCore || advertisedPrefixes4 == [ ] then
    target
  else
    let
      updatedInterfaces = builtins.mapAttrs (
        ifName: iface:
        if !(isFabricP2p iface) then
          iface
        else
          let
            peer4 = peer4For (iface.addr4 or "");
            routes = iface.routes or { };
            tenantRoutes =
              if peer4 == null then
                [ ]
              else
                builtins.map
                  (prefix: {
                    dst = prefix;
                    proto = "internal";
                    via4 = peer4;
                    intent = {
                      kind = "internal-reachability";
                      source = "tenant-subnet-return";
                    };
                  })
                  advertisedPrefixes4;
            ipv4 = (routes.ipv4 or [ ]) ++ tenantRoutes;
            ipv6 = routes.ipv6 or [ ];
          in
          iface // { routes = routes // { inherit ipv4 ipv6; }; }
      ) interfaces;
    in
    target
    // {
      effectiveRuntimeRealization = (target.effectiveRuntimeRealization or { }) // {
        interfaces = updatedInterfaces;
      };
    }
) rtAttrs
