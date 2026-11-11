{ lib
, helpers
, common
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsUpstreamRecordsForListeners ? (_listeners: [ ])
,
}:

let
  inherit (common) attrsOrEmpty failInventory listOrEmpty;
  ipam = common.ipam or { };
  # FS-540-HDS-010-SDS-010-SMS-010: the resolver source (the resolver own host or
  # loopback identity) binds to the modeled egress surface as exactly one
  # preferred-source default per address family on the modeled deterministic
  # route to that surface. Reuse the runtime-origin mechanic so the access DNS
  # resolver egress matches the overlay-egress core rule.
  runtimeOriginEgress = import ../../Unit/runtime-targets/runtime-origin-egress.nix {
    inherit lib helpers common;
    overlayNames = [ ];
  };

  stripPrefixLength =
    value:
    if !(builtins.isString value) || value == "" then "" else builtins.head (lib.splitString "/" value);
  normalizeAddress =
    value:
    let
      address = stripPrefixLength value;
      parsed6 =
        if builtins.hasAttr "parseIPv6" ipam && builtins.match ".*:.*" address != null then
          ipam.parseIPv6 address
        else
          null;
    in
    if parsed6 != null && builtins.hasAttr "renderIPv6" ipam then ipam.renderIPv6 parsed6 else address;
  familyForAddress = value:
    if builtins.match ".*:.*" (stripPrefixLength value) != null then 6 else 4;
  hostPrefixForAddress =
    value:
    let
      address = stripPrefixLength value;
      family = familyForAddress address;
    in
    if address == "" then
      null
    else
      {
        inherit family;
        prefix = "${address}/${if family == 4 then "32" else "128"}";
      };
  uniqueSourcePrefixes =
    prefixes:
    builtins.attrValues (
      builtins.listToAttrs (
        map
          (prefix: {
            name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
            value = prefix;
          })
          (builtins.filter (prefix: prefix != null && (prefix.prefix or "") != "") prefixes)
      )
    );
  uniqueStrings =
    values:
    builtins.attrNames (
      builtins.listToAttrs (
        map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter (value: builtins.isString value && value != "") values)
      )
    );
  mergeRuntimeOriginEgress =
    left: right:
    if left == null then
      right
    else if right == null then
      left
    else
      let
        leftAttrs = attrsOrEmpty left;
        rightAttrs = attrsOrEmpty right;
        sourcePrefixes = uniqueSourcePrefixes (
          listOrEmpty (leftAttrs.sourcePrefixes or null) ++ listOrEmpty (rightAttrs.sourcePrefixes or null)
        );
        uplinks = uniqueStrings (listOrEmpty (leftAttrs.uplinks or null) ++ listOrEmpty (rightAttrs.uplinks or null));
      in
      leftAttrs
      // rightAttrs
      // {
        enabled = (leftAttrs.enabled or false) || (rightAttrs.enabled or false);
        inherit sourcePrefixes;
      }
      // lib.optionalAttrs (uplinks != [ ]) { inherit uplinks; }
      // {
        preferredSources = attrsOrEmpty (leftAttrs.preferredSources or null) // attrsOrEmpty (rightAttrs.preferredSources or null);
      };
  forwarderFamily =
    forwarder:
    if builtins.match ".*:.*" forwarder != null then "ipv6" else "ipv4";

  dnsService = import ../../Unit/runtime-services/dns.nix {
    inherit lib helpers;
    inherit (common) failInventory;
  };
  inherit (dnsService) normalizeDnsService;

  routeContractForForwarder = forwarder: {
    dst = forwarder;
    source = "dns-service";
  };

  routeContractForUpstreamResolver = resolver:
    attrsOrEmpty resolver
    // {
      source = (attrsOrEmpty resolver).source or "provider-access-dns";
    };

  routeForForwarder = forwarder: {
    dst = forwarder;
    proto = "service";
    intent = {
      kind = "dns-forwarder-reachability";
      source = "dns-service";
    };
  };

  routeContractForListener = address: {
    dst = address;
    source = "router-self";
    scope = "local-access";
  };

  trafficClassForModeledResolver = target: route: {
    kind = "public-dns-traffic-classification";
    trafficClass = "modeled-resolver-traffic";
    resolverDestination = route.dst or route.destination;
    requesterScope = target.placement.target or target.logicalNode.name or "access";
    egressSurface = route.scope or route.class or route.source or "modeled-resolver";
    protocol = "tcp-udp";
    port = "53";
    dnsPolicy = "modeled-resolver-relationship";
    egressPolicy = "not-direct-public-dns";
  };

  optionalString = value:
    if builtins.isString value && value != "" then [ value ] else [ ];

  advertisedDnsListeners = advertisements:
    lib.unique (
      lib.concatMap (entry: listOrEmpty (entry.dnsServers or null)) (listOrEmpty (advertisements.dhcp4 or null))
      ++ lib.concatMap (entry: listOrEmpty (entry.rdnss or null)) (listOrEmpty (advertisements.ipv6Ra or null))
    );

  advertisedDnsSources = advertisements:
    lib.unique (
      lib.concatMap (entry: optionalString (entry.subnet or null)) (listOrEmpty (advertisements.dhcp4 or null))
      ++ lib.concatMap (entry: listOrEmpty (entry.prefixes or null)) (listOrEmpty (advertisements.ipv6Ra or null))
    );

  # Derive the reverse (PTR) zone name from a tenant prefix. IPv4 uses the
  # octet reversal of the network octets; IPv6 uses the full nibble reversal
  # (RFC 3596). No hand-written in-addr.arpa/ip6.arpa strings.
  reverseZoneForCidr = cidr:
    let
      parts = lib.splitString "/" cidr;
      addr = builtins.elemAt parts 0;
      mask = lib.toInt (builtins.elemAt parts 1);
    in
    if builtins.match ".*:.*" addr != null then
      if !(builtins.hasAttr "parseIPv6" ipam) then
        null
      else
        let
          hextets = ipam.parseIPv6 addr;
          nibbles = lib.concatMap
            (h: [
              (lib.mod h 16)
              (builtins.div h 16)
            ])
            (lib.reverseList hextets);
        in
        "${builtins.concatStringsSep "." (map builtins.toString nibbles)}.ip6.arpa."
    else
      let
        octets = builtins.filter builtins.isString (builtins.split "\\." addr);
        count = mask / 8;
        networkOctets = builtins.genList (i: builtins.elemAt octets (count - 1 - i)) count;
      in
      if builtins.length octets == 4 && count > 0 && count < 4 then
        "${builtins.concatStringsSep "." networkOctets}.in-addr.arpa."
      else
        null;

  protectedReservationPublicationsForTarget = target:
    let
      advertisements = attrsOrEmpty (target.advertisements or null);
      targetDns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
      targetRecursionMode = targetDns.recursionMode or null;
      targetLocalForwardNamespaces =
        map (zone: zone.name or "")
          (builtins.filter
            (zone: builtins.isAttrs zone && builtins.isString (zone.name or null))
            (targetDns.localForwardZones or [ ]));
      # FS-560: a DNS service that forwards a shared namespace to another
      # authority still owns the runtime reservation names of its OWN served
      # subnets. Skipping its publication because it has a forward or
      # transparent handler for the namespace drops those names entirely: the
      # authority publishes only its own records, so the forwarding scope's
      # reservations exist in the DHCP service and nowhere in DNS. Publication
      # is therefore skipped only when the resolver cannot own any name in the
      # namespace at all (local-only, or no advertised subnet of its own), not
      # merely because it forwards the rest of the namespace onward.
      advertisedSubnets =
        builtins.filter (value: builtins.isString value && value != "") (
          map (advertisement: advertisement.subnet or "") (listOrEmpty (advertisements.dhcp4 or null))
          ++ map (advertisement: advertisement.subnet or "") (listOrEmpty (advertisements.dhcp6 or null))
          ++ map (advertisement: advertisement.subnet or "") (listOrEmpty (advertisements.ipv6Ra or null))
        );
      skipPublicationFor = domainNs:
        targetRecursionMode == "local-only"
        || advertisedSubnets == [ ]
        || (
          # A namespace this resolver neither forwards nor answers locally is
          # not its business at all.
          !(builtins.elem domainNs targetLocalForwardNamespaces)
          && !(builtins.any (
            zone: builtins.isAttrs zone && (zone.name or "") == domainNs
          ) (targetDns.localZones or [ ]))
          && !(builtins.any (
            zone: builtins.isAttrs zone && (zone.name or "") == domainNs
          ) (targetDns.localRecords or [ ]))
        );
      publicationsFor = family: entries:
        builtins.filter (entry: entry != null) (
          builtins.map
            (advertisement:
              let
                source = attrsOrEmpty (advertisement.reservationSource or null);
                publication = attrsOrEmpty (source.namePublication or null);
                rawDomain = advertisement.domain or "";
                domainNs =
                  if rawDomain == "" then
                    ""
                  else if builtins.substring (builtins.stringLength rawDomain - 1) 1 rawDomain == "." then
                    rawDomain
                  else
                    "${rawDomain}.";
                skipPublication = skipPublicationFor domainNs;
              in
              # FS-560-HDS-010-SDS-010-SMS-050: an explicit namePublication record
              # is the inventory's declaration of the publication namespace
              # owner and boundary. Publication is materialized as its own local
              # authoritative boundary, so it must not additionally require a
              # pre-existing local/forward zone of the same name (that gate
              # applies to the default-publication path below).
              if publication != { } then
                let
                  pubSubnet = advertisement.subnet or "";
                  pubReverseZone =
                    if family == "ipv4" && builtins.isString pubSubnet && pubSubnet != "" then
                      let
                        parts = builtins.split "\\." pubSubnet;
                        octets = builtins.filter builtins.isString parts;
                      in
                      if builtins.length octets >= 3 then
                        "${builtins.elemAt octets 2}.${builtins.elemAt octets 1}.${builtins.elemAt octets 0}.in-addr.arpa."
                      else
                        null
                    else
                      null;
                in
                {
                  source = {
                    schema = source.schema;
                    sourceClass = source.sourceClass;
                    sourceFile = source.sourceFile;
                  };
                  scopeId = advertisement.id;
                  namespace = publication.namespace;
                  ownerScope = publication.ownerScope;
                  requesterScopes = publication.requesterScopes;
                  recordClasses = publication.recordClasses;
                  fallbackBehavior = publication.fallbackBehavior;
                  publicationDenialDiagnostic = publication.publicationDenialDiagnostic;
                  materializerFamily = family;
                  reverseNamespace = if builtins.elem "PTR" publication.recordClasses then pubReverseZone else null;
                }
              # FS-560-HDS-010-SDS-010-SMS-050: when a protected reservation source
              # exists without an explicit namePublication contract, emit a default
              # publication with the standard DHCP domain namespace — but only for
              # targets that are the authority for that namespace (not local-only
              # forwarders). This keeps runtime reservation hostnames out of
              # inventory, flake eval output, and the Nix store while publishing A,
              # AAAA, and PTR through the renderer-owned protected materializer.
              else if
                !skipPublication
                && (source.schema or null) == "gamp-protected-reservation-set-v1"
                && (source.sourceClass or null) == "protected"
                && builtins.isString (source.sourceFile or null)
                && source.sourceFile != ""
              then
                let
                  # Derive the reverse-DNS zone for PTR records from the
                  # advertisement subnet so the renderer can publish both
                  # forward (lan.) and reverse (in-addr.arpa / ip6.arpa)
                  # local zones.
                  subnet = advertisement.subnet or "";
                  # Derive the IPv4 reverse-DNS zone from the advertisement
                  # subnet.  For 192.168.1.0/24 this yields
                  # 1.168.192.in-addr.arpa. so Unbound local-data-ptr records
                  # are answered authoritatively.
                  reverseZone =
                    if family == "ipv4" && builtins.isString subnet && subnet != "" then
                      let
                        parts = builtins.split "\\." subnet;
                        octets = builtins.filter builtins.isString parts;
                      in
                      if builtins.length octets >= 3 then
                        "${builtins.elemAt octets 2}.${builtins.elemAt octets 1}.${builtins.elemAt octets 0}.in-addr.arpa."
                      else
                        null
                    else
                      null;
                in
                {
                  source = {
                    schema = source.schema;
                    sourceClass = source.sourceClass;
                    sourceFile = source.sourceFile;
                  };
                  scopeId = advertisement.id;
                  namespace = domainNs;
                  ownerScope = advertisement.id;
                  requesterScopes = [ advertisement.id ];
                  recordClasses = [
                    "A"
                    "AAAA"
                    "PTR"
                  ];
                  fallbackBehavior = "local-only";
                  publicationDenialDiagnostic = "protected-reservation-publication-default-fallback";
                  materializerFamily = family;
                  reverseNamespace = reverseZone;
                }
              else
                null)
            entries
        );
      raw =
        publicationsFor "ipv4" (listOrEmpty (advertisements.dhcp4 or null))
        ++ publicationsFor "ipv6" (listOrEmpty (advertisements.dhcpv6 or null));
      keyed = builtins.listToAttrs (
        builtins.map
          (publication: {
            name = "${publication.source.sourceFile}|${publication.scopeId}|${publication.namespace}";
            value = publication;
          })
          raw
      );
    in
    builtins.attrValues keyed;

  runtimeTargetPath = target:
    "runtimeTargets.${target.placement.target or target.logicalNode.name or "access"}";

  runtimeTargetScope = target:
    target.placement.target or target.logicalNode.name or "access";

  routeContractForResolverAdvertisement = target: dns: address:
    let
      matches =
        builtins.filter
          (route:
            builtins.isAttrs route
            && (route.dst or null) == address
            && (route.source or null) == "router-self"
            && (route.scope or null) == "local-access")
          (listOrEmpty (dns.routeContracts or null));
    in
    if matches != [ ] then
      builtins.head matches
    else
      failInventory
        "${runtimeTargetPath target}.services.dns.routeContracts"
        "resolver advertisement for '${address}' lacks modeled local-access DNS policy authority";

  trafficClassificationForResolverAdvertisement = target: dns: address:
    let
      matches =
        builtins.filter
          (classification:
            builtins.isAttrs classification
            && (classification.kind or null) == "public-dns-traffic-classification"
            && (classification.trafficClass or null) == "modeled-resolver-traffic"
            && (classification.resolverDestination or null) == address
            && (classification.dnsPolicy or null) == "modeled-resolver-relationship")
          (listOrEmpty (dns.publicDnsTrafficClassifications or null));
    in
    if matches != [ ] then
      builtins.head matches
    else
      failInventory
        "${runtimeTargetPath target}.services.dns.publicDnsTrafficClassifications"
        "resolver advertisement for '${address}' lacks modeled DNS traffic classification";

  resolverAdvertisementRecord = target: dns: transport: requiredDiscoveryOption: addressFamily: entry: address:
    let
      targetScope = runtimeTargetScope target;
      routeContract = routeContractForResolverAdvertisement target dns address;
      trafficClassification = trafficClassificationForResolverAdvertisement target dns address;
      tenant = entry.tenant or null;
      sourceInterface = entry.interface or null;
      attachmentSurface = entry.bindInterface or sourceInterface;
    in
    {
      kind = "dns-resolver-advertisement";
      source = "modeled-resolver-relationship";
      inherit transport requiredDiscoveryOption addressFamily;
      requesterScope = targetScope;
      requesterRole = "tenant-client";
      responderScope = targetScope;
      resolverServiceRole = "access-resolver";
      accessSpace = tenant;
      tenant = tenant;
      sourceInterface = sourceInterface;
      attachmentSurface = attachmentSurface;
      advertisedResolverIdentity = address;
      resolverAddress = address;
      resolverPurpose = "client-recursive-resolver-candidate";
      dnsPolicy = "modeled-resolver-relationship";
      advertisementGrantsRecursion = false;
      advertisementGrantsUpstreamForwarding = false;
      advertisementGrantsPublicDnsEgress = false;
      policyReferences = {
        dnsService = "${runtimeTargetPath target}.services.dns";
        inherit routeContract trafficClassification;
      };
    };

  resolverAdvertisementsForTarget = target:
    let
      advertisements = attrsOrEmpty (target.advertisements or null);
      dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
      dhcp4Records =
        lib.concatMap
          (entry:
            builtins.map
              (address: resolverAdvertisementRecord target dns "dhcp4" "dhcp-option-6" "ipv4" entry address)
              (listOrEmpty (entry.dnsServers or null)))
          (listOrEmpty (advertisements.dhcp4 or null));
      dhcpv6Records =
        lib.concatMap
          (entry:
            builtins.map
              (address: resolverAdvertisementRecord target dns "dhcpv6" "dhcpv6-option-23" "ipv6" entry address)
              (listOrEmpty (entry.dnsServers or null)))
          (listOrEmpty (advertisements.dhcpv6 or null));
      ipv6RaRecords =
        lib.concatMap
          (entry:
            builtins.map
              (address: resolverAdvertisementRecord target dns "ipv6-ra" "ra-rdnss" "ipv6" entry address)
              (listOrEmpty (entry.rdnss or null)))
          (listOrEmpty (advertisements.ipv6Ra or null));
    in
    dhcp4Records ++ dhcpv6Records ++ ipv6RaRecords;

  addResolverAdvertisementContracts = target:
    let
      resolverAdvertisements = resolverAdvertisementsForTarget target;
    in
    if resolverAdvertisements == [ ] then
      target
    else
      target // {
        advertisements =
          attrsOrEmpty (target.advertisements or null)
          // { inherit resolverAdvertisements; };
      };

  addForwarderRoutes =
    target: forwarders:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      routesByFamily = {
        ipv4 = builtins.map routeForForwarder (builtins.filter (f: forwarderFamily f == "ipv4") forwarders);
        ipv6 = builtins.map routeForForwarder (builtins.filter (f: forwarderFamily f == "ipv6") forwarders);
      };
      updatedInterfaces =
        builtins.mapAttrs
          (_: iface:
            if (iface.sourceKind or null) != "p2p" then
              iface
            else
              let
                routes = attrsOrEmpty (iface.routes or null);
              in
              iface
              // {
                routes = {
                  ipv4 = listOrEmpty (routes.ipv4 or null) ++ routesByFamily.ipv4;
                  ipv6 = listOrEmpty (routes.ipv6 or null) ++ routesByFamily.ipv6;
                };
              })
          interfaces;
    in
    if interfaces == { } || forwarders == [ ] then
      target
    else
      let
        withRoutes = target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };
        # Bind the resolver source to the modeled egress as exactly one
        # preferred-source default per family (FS-540).
        roe = withRoutes.runtimeOriginEgress or null;
      in
      withRoutes
      // {
        effectiveRuntimeRealization =
          (withRoutes.effectiveRuntimeRealization)
          // {
            interfaces = runtimeOriginEgress.applyToInterfaces roe updatedInterfaces;
          };
      };

  dnsServiceRuntimeOriginEgressContract =
    target: dns:
    let
      roles = attrsOrEmpty (dns.roles or null);
      recursionRole = attrsOrEmpty (roles.recursion or null);
      recursionSources = listOrEmpty (recursionRole.outgoingInterfaces or null);
      outgoingSources = listOrEmpty (dns.outgoingInterfaces or null);
      listenSources = listOrEmpty (dns.listen or null);
      sourceAddresses =
        if recursionSources != [ ] then
          recursionSources
        else if outgoingSources != [ ] then
          outgoingSources
        else
          listenSources;
      sourcePrefixes = uniqueSourcePrefixes (map hostPrefixForAddress sourceAddresses);
      ipv4Sources = builtins.filter (addr: familyForAddress addr == 4) sourceAddresses;
      ipv6Sources = builtins.filter (addr: familyForAddress addr == 6) sourceAddresses;
      ipv4Source = if ipv4Sources == [ ] then "" else builtins.head ipv4Sources;
      ipv6Source = if ipv6Sources == [ ] then "" else builtins.head ipv6Sources;
      hasExplicitEgress = builtins.elem "explicit-egress-default" (listOrEmpty (dns.allowedUpstreamClasses or null));
      hasModeledUpstream =
        listOrEmpty (dns.forwarders or null) != [ ]
        || listOrEmpty (dns.upstreamResolvers or null) != [ ];
    in
    if (target.role or null) == "access" && hasExplicitEgress && hasModeledUpstream && sourcePrefixes != [ ] then
      {
        enabled = true;
        source = "dns-service";
        preferredSources =
          lib.optionalAttrs (ipv4Source != "") { ipv4 = stripPrefixLength ipv4Source; }
          // lib.optionalAttrs (ipv6Source != "") { ipv6 = stripPrefixLength ipv6Source; };
        inherit sourcePrefixes;
      }
    else
      null;

  addDnsServiceRuntimeOriginEgress =
    target: dns:
    let
      contract = dnsServiceRuntimeOriginEgressContract target dns;
    in
    if contract == null then
      target
    else
      target // {
        runtimeOriginEgress = mergeRuntimeOriginEgress (target.runtimeOriginEgress or null) contract;
      };

  synthesizeRouterSelfDns = target:
    let
      advertisements = attrsOrEmpty (target.advertisements or null);
      advertisedListeners = advertisedDnsListeners advertisements;
      # A resolver that fabric peers query must listen on the address those peers
      # route to, and that address is never an advertised one.
      #
      # `advertisedDnsListeners` collects the DNS servers broadcast over DHCP and
      # RA, which are by construction the addresses *tenants* are told to use. A
      # resolver reached across the fabric publishes no advertisement for that
      # side, so its fabric address never entered `listen`, and unbound bound
      # loopback plus the tenant-facing addresses only.
      #
      # Measured on the cobalt HAT, the access resolver ran with
      #   interface: 127.0.0.1 / ::1 / 10.2.30.1 / fd42:dead:beef:230::1
      # and no fabric address, while its fabric address is 10.1.0.0/31 on the
      # downstream-selector lane. Querying it returned `connection refused` -- not
      # a timeout -- so the address was correct and routable and only the listener
      # was absent.
      #
      # These are added to the emitted `listen` list ONLY. They deliberately do
      # not join `listeners`, because `listeners` also feeds
      # `resolverIdentitySources` and the `accessFrom` ACL, where a core-service
      # prefix (10.19.0.8/32 in FS-400's fixture) must never appear: FS-550 and
      # FS-540 both treat those as non-listener. Widening `listeners` instead
      # failed test-runtime-origin-dns-provider-allow-from and FS-540.
      #
      # Selected by explicit `interfaceClass` metadata, never by interface name:
      # FS-310-HDS-010-SDS-010-SMS-120 forbids deriving network meaning from name
      # patterns.
      fabricListeners =
        let
          realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
          interfaces = attrsOrEmpty (realization.interfaces or null);
          facesFabric =
            iface:
            let
              cls = attrsOrEmpty (iface.interfaceClass or null);
            in
            ((cls.edgeFacing or false) || (cls.fabricFacing or false))
            && !(cls.exitFacing or false)
            && !(cls.uplinkLane or false);
          addressesOf =
            iface:
            lib.optional ((iface.addr4 or null) != null) iface.addr4
            ++ lib.optional ((iface.addr6 or null) != null) iface.addr6;
        in
        # A target that advertises nothing is not running a resolver at all: do
        # not invent a listener for it. FS-540's fixture has no `listen` and
        # expects no fabric listener either.
        if advertisedListeners == [ ] then
          [ ]
        else
          lib.unique (
            builtins.concatMap (
              name:
              let
                iface = interfaces.${name};
              in
              if facesFabric iface then
                builtins.filter
                  (addr: builtins.isString addr && addr != "" && addr != "127.0.0.1" && addr != "::1")
                  (map stripPrefixLength (addressesOf iface))
              else
                [ ]
            ) (builtins.attrNames interfaces)
          );
      # The peer side of each fabric lane: the remote address a query arrives
      # from, as a single host prefix. `listen` names the local end; this names
      # the end that is allowed to ask.
      fabricPeerPrefixes =
        let
          realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
          interfaces = attrsOrEmpty (realization.interfaces or null);
          facesFabric =
            iface:
            let
              cls = attrsOrEmpty (iface.interfaceClass or null);
            in
            !(cls.exitFacing or false) && !(cls.uplinkLane or false);
          peerPrefix =
            iface:
            let
              addr4 = iface.addr4 or null;
              addr6 = iface.addr6 or null;
              peerOf =
                value:
                let
                  parts = lib.splitString "/" value;
                  ip = builtins.head parts;
                  len = if builtins.length parts > 1 then builtins.elemAt parts 1 else "";
                in
                if len == "31" || len == "127" then
                  # Flip the last bit: the other end of the point-to-point link.
                  let
                    octets = lib.splitString "." ip;
                  in
                  if builtins.length octets == 4 then
                    let
                      last = builtins.fromJSON (builtins.elemAt octets 3);
                      flipped = builtins.toJSON (if builtins.bitAnd last 1 == 1 then last - 1 else last + 1);
                      head' = lib.take 3 octets;
                    in
                    "${lib.concatStringsSep "." head'}.${flipped}/32"
                  else
                    null
                else
                  null;
            in
            builtins.filter (v: v != null) (
              lib.optional (builtins.isString addr4) (peerOf addr4)
              ++ lib.optional (builtins.isString addr6) (peerOf addr6)
            );
        in
        if advertisedListeners == [ ] then
          [ ]
        else
          lib.unique (builtins.concatMap (name: peerPrefix interfaces.${name}) (builtins.attrNames interfaces));

      # The fabric listen addresses are part of the listener identity: FS-540
      # requires outgoingInterfaces == listen, and a recursion source must be a
      # real listener. Keeping them out of `listeners` made `listen` list an
      # address the resolver would not bind from.
      listeners = lib.unique (advertisedListeners ++ fabricListeners);
      sources = advertisedDnsSources advertisements;
      derivedReverseZones = builtins.filter (z: z != null) (map reverseZoneForCidr sources);
      listenerPolicyForwarders = policyDerivedDnsForwardersForListeners listeners;
      listenerPolicyUpstreamResolvers = policyDerivedDnsUpstreamRecordsForListeners listeners;
      listenerPolicyAllowedClasses = policyDerivedDnsAllowedClassesForListeners listeners;
      existingServices = attrsOrEmpty (target.services or null);
      hasModeledDnsPolicy = existingServices ? dns;
      existingDns = attrsOrEmpty (existingServices.dns or null);
      protectedReservationPublications = protectedReservationPublicationsForTarget target;
      existingForwarders = listOrEmpty (existingDns.forwarders or null);
      existingUpstreamResolvers = listOrEmpty (existingDns.upstreamResolvers or null);
      derivedUpstreamResolvers = listenerPolicyUpstreamResolvers;
      upstreamResolvers =
        if existingUpstreamResolvers != [ ] then
          existingUpstreamResolvers
        else
          derivedUpstreamResolvers;
      derivedForwarders = listenerPolicyForwarders;
      forwarders =
        if upstreamResolvers != [ ] then
          [ ]
        else if existingForwarders != [ ] then
          existingForwarders
        else
          derivedForwarders;
      # GAMP: FS-540-HDS-010-SDS-010-SMS-035 — filter self-referential forwarders
      nonLoopbackListeners = builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listeners;
      listenerAddressIndex = builtins.listToAttrs (
        builtins.map
          (addr: {
            name = normalizeAddress addr;
            value = true;
          })
          nonLoopbackListeners
      );
      isSelfRefForwarder = forwarder: builtins.hasAttr (normalizeAddress forwarder) listenerAddressIndex;
      selfRefForwarders = builtins.filter isSelfRefForwarder forwarders;
      selfFilteredForwarders = builtins.filter (f: !(isSelfRefForwarder f)) forwarders;
      safeForwarders =
        if selfRefForwarders != [ ] then
          builtins.trace
            "FS-540-HDS-010-SDS-010-SMS-035: filtered self-referential DNS forwarder input without logging address material"
            (if selfFilteredForwarders == [ ] && derivedForwarders != [ ] then derivedForwarders else selfFilteredForwarders)
        else
          forwarders;
      allowedUpstreamClasses =
        lib.unique (
          listOrEmpty (existingDns.allowedUpstreamClasses or null)
          ++ listenerPolicyAllowedClasses
        );
      roles = attrsOrEmpty (existingDns.roles or null);
      recursionRole = attrsOrEmpty (roles.recursion or null);
      # FS-540-HDS-010-SDS-010-SMS-020: the resolver's own modeled service
      # identity is the non-loopback addresses it was given as a resolver. When
      # the resolver does not advertise listeners (a core resolver reached
      # through a service path), that identity is its modeled, non-loopback
      # interface addresses; leaving the source unbound would let the query
      # egress from whichever address the default route selects.
      # The resolver's identity is the set of addresses it can be reached on.
      # Only fabric-facing lanes qualify: an exit/uplink surface carries core
      # service prefixes (FS-400's fixture has 10.19.0.8/32) which are
      # destinations, not listener identities, and putting them here made the
      # provider ACL advertise them (test-runtime-origin-dns-provider-allow-from,
      # FS-550).
      serviceIdentitySources =
        let
          ifaces = attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);
          addressesOf =
            iface:
            builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") (
              (lib.optional (builtins.isString (iface.addr4 or null)) (stripPrefixLength iface.addr4))
              ++ (lib.optional (builtins.isString (iface.addr6 or null)) (stripPrefixLength iface.addr6))
            );
          # Include every interface that is not an exit/uplink surface. Listing
          # the classes to *include* was wrong twice: it dropped the nebula lane
          # (FS-540's 100.96.10.1) because that lane is neither edgeFacing nor
          # fabricFacing. Excluding the exit surfaces is the invariant that
          # actually matters -- those carry core service prefixes (10.19.0.8/32)
          # which are destinations, not listener identities.
          faceable =
            iface:
            let
              cls = attrsOrEmpty (iface.interfaceClass or null);
            in
            !(cls.exitFacing or false) && !(cls.uplinkLane or false);
        in
        lib.unique (builtins.concatMap addressesOf (builtins.filter faceable (builtins.attrValues ifaces)));
      resolverIdentitySources =
        let
          advertised = builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listeners;
        in
        if advertised != [ ] then advertised else serviceIdentitySources;
      recursionOutgoingInterfaces =
        if listOrEmpty (recursionRole.outgoingInterfaces or null) != [ ] then
          listOrEmpty (recursionRole.outgoingInterfaces or null)
        else if listOrEmpty (existingDns.outgoingInterfaces or null) != [ ] then
          listOrEmpty (existingDns.outgoingInterfaces or null)
        else if safeForwarders != [ ] then
          builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listeners
        else if upstreamResolvers != [ ] then
          resolverIdentitySources
        else
          [ ];
      localContracts = builtins.map routeContractForListener listeners;
      mergedDns =
        existingDns
        // {
          listen = lib.unique (listOrEmpty (existingDns.listen or null) ++ listeners);
          # Admitting the fabric peers is the other half of the listener fix: an
          # address that is bound but not allow-listed answers `refuse_non_local`,
          # which is exactly what the cobalt HAT showed (`dig` returned a reply
          # with no question section). Only the peer side of each fabric lane is
          # added -- the narrower /31 or /127 -- so the ACL does not pick up whole
          # interface prefixes.
          allowFrom = lib.unique (
            listOrEmpty (existingDns.allowFrom or null) ++ sources ++ fabricPeerPrefixes
          );
          blockDirectEgress = true;
          directEgressBlockedTenants = listOrEmpty (existingDns.directEgressBlockedTenants or null);
          forwarders = safeForwarders;
          upstreamResolvers = upstreamResolvers;
          allowedUpstreamClasses = allowedUpstreamClasses;
          outgoingInterfaces =
            if listOrEmpty (existingDns.outgoingInterfaces or null) != [ ] then
              listOrEmpty (existingDns.outgoingInterfaces or null)
            else if safeForwarders != [ ] then
              resolverIdentitySources
            else if upstreamResolvers != [ ] then
              resolverIdentitySources
            else
              [ ];
          roles = roles // { recursion = recursionRole // { outgoingInterfaces = recursionOutgoingInterfaces; }; };
          localZones = lib.unique (
            (listOrEmpty (existingDns.localZones or null))
            ++ map
              (z: {
                name = z;
                type = "static";
              })
              derivedReverseZones
          );
          routeContracts = lib.unique (listOrEmpty (existingDns.routeContracts or null) ++ localContracts);
          policyMatrix = lib.unique (listOrEmpty (existingDns.policyMatrix or null) ++ localContracts);
        }
        // lib.optionalAttrs (protectedReservationPublications != [ ]) {
          inherit protectedReservationPublications;
        };
    in
    # FS-540-HDS-010-SDS-010-SMS-020: a core resolver reached through a service
    # path still binds its recursion source to its modeled service identity
    # (its non-loopback listener/interface addresses). Only the
    # advertisement-driven synthesis is access-specific; the identity binding
    # applies whenever the resolver has modeled DNS policy or forwarders, or
    # advertised listeners.
    if (target.role or null) != "access" && advertisedListeners == [ ] && !hasModeledDnsPolicy && existingForwarders == [ ] then
      target
    else if (target.role or null) == "access" && advertisedListeners == [ ] then
      target
    else if (target.role or null) == "access" && !hasModeledDnsPolicy then
      builtins.deepSeq listenerPolicyForwarders
        (
          builtins.deepSeq listenerPolicyUpstreamResolvers (
            builtins.deepSeq listenerPolicyAllowedClasses (
              failInventory
                "${runtimeTargetPath target}.services.dns"
                "missing modeled DNS policy for resolver advertisement; define services.dns before renderer-facing advertisement output"
            )
          )
        )
    else
      target
      // {
        services = (attrsOrEmpty (target.services or null)) // {
          dns = (normalizeDnsService "${runtimeTargetPath target}.services" mergedDns) // {
            blockDirectEgress = true;
          };
        };
      };
in
target:
let
  targetWithDns = synthesizeRouterSelfDns target;
  dns = attrsOrEmpty (targetWithDns.services.dns or null);
  forwarders = listOrEmpty (dns.forwarders or null);
  upstreamResolverContracts = builtins.map routeContractForUpstreamResolver (listOrEmpty (dns.upstreamResolvers or null));
  suppressForwarderContracts = upstreamResolverContracts != [ ] && forwarders == [ ];
  dnsWithUpstreamResolverContracts =
    if upstreamResolverContracts == [ ] then
      dns
    else
      let
        # A resolver that forwards to another resolver needs egress authority just
        # as one with forwarders does: it originates its own queries toward that
        # upstream. Without this the access resolver carried route contracts but no
        # `explicit-egress-default`, so
        # `dnsServiceRuntimeOriginEgressContract` returned null for it and the node
        # published no `runtimeOriginEgress` at all.
        #
        # Measured on the cobalt HAT: access.services.dns.allowedUpstreamClasses was
        # [ "local-access" ], runtimeOriginEgress was ABSENT, and four consumers then
        # each guessed the resolver's source differently -- the policy forward rule
        # used the service address (10.2.30.1), the kernel used the interface
        # address (10.1.0.0), the core's ACL refused the fabric peer, and the DS's
        # route pointed at the ingress peer. One missing field, four symptoms.
        allowedUpstreamClasses = lib.unique (
          listOrEmpty (dns.allowedUpstreamClasses or null) ++ [ "explicit-egress-default" ]
        );
        roles = attrsOrEmpty (dns.roles or null);
        recursionRole = attrsOrEmpty (roles.recursion or null);
      in
      dns
      // {
        inherit allowedUpstreamClasses;
        roles = roles // {
          recursion = recursionRole // { inherit allowedUpstreamClasses; };
        };
        routeContracts = listOrEmpty (dns.routeContracts or null) ++ upstreamResolverContracts;
        policyMatrix = listOrEmpty (dns.policyMatrix or null) ++ upstreamResolverContracts;
      };
  dnsContracts =
    if forwarders == [ ] then
      dnsWithUpstreamResolverContracts
    else
      let
        allowedUpstreamClasses =
          lib.unique (
            listOrEmpty (dns.allowedUpstreamClasses or null)
            ++ (if forwarders != [ ] then [ "explicit-egress-default" ] else [ ])
          );
        roles = attrsOrEmpty (dns.roles or null);
        recursionRole = attrsOrEmpty (roles.recursion or null);
      in
      dns
      // {
        allowedUpstreamClasses = allowedUpstreamClasses;
        roles = roles // { recursion = recursionRole // { allowedUpstreamClasses = allowedUpstreamClasses; }; };
        routeContracts = listOrEmpty (dns.routeContracts or null) ++ upstreamResolverContracts ++ builtins.map routeContractForForwarder forwarders;
        policyMatrix = listOrEmpty (dns.policyMatrix or null) ++ upstreamResolverContracts ++ builtins.map routeContractForForwarder forwarders;
      };
  dnsWithTrafficClassifications =
    let
      modeledResolverRoutes =
        builtins.filter
          (route: builtins.isAttrs route && (route.source or null) == "router-self" && (route.dst or null) != null)
          (listOrEmpty (dnsContracts.routeContracts or null));
      modeledResolverClasses =
        builtins.map (trafficClassForModeledResolver targetWithDnsContracts) modeledResolverRoutes;
      publicDnsTrafficClassifications = modeledResolverClasses;
    in
    if publicDnsTrafficClassifications == [ ] then
      dnsContracts
    else
      dnsContracts // { inherit publicDnsTrafficClassifications; };
  targetWithDnsContracts =
    targetWithDns
    // {
      services = (attrsOrEmpty (targetWithDns.services or null)) // { dns = dnsWithTrafficClassifications; };
    };
  targetWithDnsServiceRuntimeOriginEgress =
    addDnsServiceRuntimeOriginEgress targetWithDnsContracts dnsWithTrafficClassifications;
  targetWithResolverAdvertisementContracts =
    addResolverAdvertisementContracts targetWithDnsServiceRuntimeOriginEgress;
in
if dns == { } then
  targetWithDns
else if suppressForwarderContracts then
  targetWithResolverAdvertisementContracts
else if forwarders == [ ] then
  targetWithResolverAdvertisementContracts
else if (targetWithDns.role or null) != "access" then
  targetWithResolverAdvertisementContracts
else
  addForwarderRoutes
    targetWithResolverAdvertisementContracts
    forwarders
