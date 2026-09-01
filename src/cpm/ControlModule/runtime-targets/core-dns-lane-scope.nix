# FS-540: Filter core-resolver routes that leaked into non-requester policy
# lanes.  The NFM internal-route plan places service-endpoint routes on every
# p2p interface of a transit node, which copies core DNS resolver entries
# across VLAN 2, VLAN 3, and VLAN 7 policy tables.  Until the NFM emits
# per-lane service-route plans, strip the leaked routes from interfaces whose
# lane does not match the requester.
{ lib, common }:

runtimeTargets:

let
  inherit (common) attrsOrEmpty listOrEmpty;
  targetNames = builtins.attrNames runtimeTargets;

  # Gather core DNS resolver addresses from core target endpoint bindings.
  coreDnsAddrs =
    let
      coreTargets = builtins.filter
        (tn:
          let t = runtimeTargets.${tn};
          in (t.role or null) == "core")
        targetNames;
      coreAddrs =
        if coreTargets == [ ] then
          { }
        else
          let
            t = runtimeTargets.${builtins.head coreTargets};
            dns = attrsOrEmpty ((attrsOrEmpty (t.services or null)).dns or null);
            bindings = listOrEmpty (dns.serviceEndpointBindings or null);
          in
          if bindings == [ ] then
            { }
          else
            let b = builtins.head bindings;
            in {
              ipv4 = listOrEmpty (b.ipv4 or null);
              ipv6 = listOrEmpty (b.ipv6 or null);
            };
      dns4 = coreAddrs.ipv4 or [ ];
      dns6 = coreAddrs.ipv6 or [ ];
    in
    dns4 ++ dns6;

  # Which lane (access name) a p2p interface belongs to, if any.
  laneAccessFor =
    iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      access = lane.access or null;
    in
    if builtins.isString access && access != "" then access else null;

  # Authorized requester lanes are the access targets that carry a
  # named-dns-binding service endpoint binding. The access target name IS
  # the lane access identity, so no string-matching on the requester name
  # is needed.
  requesterLanes =
    let
      accessTargets = builtins.filter
        (tn:
          let t = runtimeTargets.${tn};
          in (t.role or null) == "access")
        targetNames;
      lanesFor = tn:
        let
          t = runtimeTargets.${tn};
          dns = attrsOrEmpty ((attrsOrEmpty (t.services or null)).dns or null);
          bindings = listOrEmpty (dns.serviceEndpointBindings or null);
        in
        if bindings == [ ] then [ ] else [ tn ];
    in
    lib.unique (lib.concatMap lanesFor accessTargets);

  # Determine which policy-facing interfaces belong to authorized requester
  # lanes so we only keep core DNS routes on those interfaces.
  authorizedLaneFor =
    iface:
    let
      access = laneAccessFor iface;
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      uplink = lane.uplink or null;
    in
    if access == null || uplink == null then
      null
    else if builtins.elem access requesterLanes then
      # Downstream half: check that the lane matches an authorized requester
      let
        isDownstream = builtins.match ".*downstream.*" (iface.renderedName or iface.renderedIfName or "");
        isUpstream = builtins.match ".*upstream.*" (iface.renderedName or iface.renderedIfName or "");
      in
      if isDownstream != null || isUpstream != null then access else null
    else
      null;

  # Strip core DNS routes from interfaces on non-requester lanes.
  filterRoutesFor = targetName: target:
    let
      role = target.role or null;
    in
    if !(builtins.elem role [ "policy" "upstream-selector" "downstream-selector" ]) then
      target
    else if coreDnsAddrs == [ ] then
      target
    else
      let
        realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
        interfaces = attrsOrEmpty (realization.interfaces or null);
        filteredInterfaces = builtins.mapAttrs
          (ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              lane = authorizedLaneFor iface;
              keep = if lane != null then
                # This interface is on an authorized requester lane — keep
                # core DNS routes.
                routes
              else
                # Non-requester lane — strip core DNS resolver routes.
                let
                  strip = family: rs:
                    builtins.filter
                      (r:
                        let dst = r.dst or r.destination or "";
                        in !(builtins.elem dst coreDnsAddrs))
                      (listOrEmpty rs);
                in
                {
                  ipv4 = strip 4 (routes.ipv4 or null);
                  ipv6 = strip 6 (routes.ipv6 or null);
                };
            in
            iface // { inherit routes; } // (if lane == null then { routes = keep; } else { }))
          interfaces;
      in
      target // {
        effectiveRuntimeRealization = realization // {
          interfaces = filteredInterfaces;
        };
      };
in
builtins.mapAttrs filterRoutesFor runtimeTargets
