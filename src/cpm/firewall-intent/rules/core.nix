{ common }:

{ tenantPrefixOwners ? { }
, transitInterfaces
, uplinkInterfaces
, dnsServicePublicEgressRules ? [ ]
,
}:
let
  delegatedOverlayEgress = import ./core-delegated-overlay-egress.nix { inherit tenantPrefixOwners; };

  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  # Every tenant prefix owned by this site; used to make the core fabric-to-
  # uplink egress enforceable (the WAN surface is external, so the forward leg
  # cannot carry a dedicated-link isolation proof).
  allTenantPrefixes =
    builtins.filter
      (entry: entry != null)
      (builtins.map
        (key:
          let
            value = tenantPrefixOwners.${key} or { };
            parts = builtins.split "\\|" key;
            familyPart = builtins.elemAt parts 0;
            prefixPart = builtins.elemAt parts 2;
            family = if familyPart == "6" then 6 else 4;
          in
          if (value.kind or null) == "runtime-routed-prefix" && family == 6 then
            {
              inherit family;
              kind = "sourceFile";
              sourceFile = value.sourceFile or null;
              slot = value.slot or null;
              delegatedPrefixLength = value.delegatedPrefixLength or null;
              perTenantPrefixLength = value.perTenantPrefixLength or null;
            }
          else if (value.kind or null) == "runtime-routed-prefix" then
            null
          else
            {
              inherit family;
              prefix = prefixPart;
            })
        (builtins.attrNames tenantPrefixOwners));

  traceIdFor = iface:
    let
      scope = common.interfaceScope iface;
      ref = scope.backingRef or { };
    in
    if builtins.isString (ref.id or null) && ref.id != "" then
      ref.id
    else if builtins.isString (scope.logicalInterface or null) && scope.logicalInterface != "" then
      scope.logicalInterface
    else
      iface.runtimeIfName;

  originRefFor = iface:
    let
      scope = common.interfaceScope iface;
    in
    {
      backingRef = scope.backingRef or { };
      logicalInterface = scope.logicalInterface or null;
      sourceKind = scope.sourceKind or null;
    };

  # FS-270-HDS-010-SDS-010-SMS-010: core-transit-mesh admission is policy
  # authority, not topology provenance. A relation ID, comment, or non-bypass
  # label proves origin but never authorizes packets. Interface-pair transport
  # without enforceable packet matches is admissible only with a complete
  # dedicated-link isolation proof:
  #   - the surface is a modeled dedicated point-to-point transport
  #     (a fabric link record, or a pppoe session whose peer runtime target
  #     is modeled in the same inventory), and
  #   - the surface is not marked external — an inventory surface with
  #     external = true is a public provider surface and shall never be
  #     admitted to core-transit-mesh or generate a bare
  #     public-to-internal interface accept.
  # Host-local separation for admitted transit surfaces is owned by sibling
  # FS-270-HDS-010-SDS-010-SMS-030.
  backingRefOf = iface: attrsOrEmpty (iface.backingRef or null);

  isExternalSurface = iface:
    (iface.external or false) == true
    || ((attrsOrEmpty (iface.wan or null)).external or false) == true
    || ((backingRefOf iface).external or false) == true
    || ((attrsOrEmpty (iface.interfaceClass or null)).providerSession or false) == true
    || (iface.sessionPurpose or null) == "provider-access";

  modeledPeerRef = iface:
    let
      ref = backingRefOf iface;
    in
    if (ref.kind or null) == "link" && builtins.isString (ref.id or null) && ref.id != "" then
      {
        kind = "fabric-link";
        id = ref.id;
      }
    else if
      (ref.kind or null) == "pppoe-session"
      && builtins.isString (ref.peerRuntimeTarget or null)
      && ref.peerRuntimeTarget != ""
    then
      {
        kind = "modeled-session-peer";
        id = ref.id or null;
        peerRuntimeTarget = ref.peerRuntimeTarget;
      }
    else
      null;

  transitIsolationProof = iface:
    let
      peer = modeledPeerRef iface;
    in
    if isExternalSurface iface then
      {
        admissible = false;
        surface = iface.runtimeIfName;
        sourceKind = iface.sourceKind or null;
        reason = "external-surface-not-core-transit";
      }
    else if peer == null then
      {
        admissible = false;
        surface = iface.runtimeIfName;
        sourceKind = iface.sourceKind or null;
        reason = "provenance-without-isolation-authority";
      }
    else
      {
        admissible = true;
        surface = iface.runtimeIfName;
        sourceKind = iface.sourceKind or null;
        dedicated = true;
        external = false;
        modeledPeer = peer;
        hostFacing = iface.hostFacing or false;
        hostLocalSeparation = "FS-270-HDS-010-SDS-010-SMS-030";
      };

  admissibleTransitInterfaces =
    builtins.filter (iface: (transitIsolationProof iface).admissible) transitInterfaces;

  deniedTransitSurfaces =
    builtins.filter (iface: !(transitIsolationProof iface).admissible) transitInterfaces;

  transitAdmission = {
    module = "FS-270-HDS-010-SDS-010-SMS-010";
    admitted = map (iface: transitIsolationProof iface) admissibleTransitInterfaces;
    denied = map
      (iface:
        (transitIsolationProof iface) // {
          diagnostic = "core-transit-admission-denied";
          failClosed = true;
        })
      deniedTransitSurfaces;
  };

  coreTransitAudit = fromIface: toIface:
    let
      direction = "core-transit-mesh";
      relationId = "core-transit-mesh--${traceIdFor fromIface}--${traceIdFor toIface}";
    in
    {
      inherit relationId direction;
      comment = relationId;
      trafficType = "any";
      from = common.interfaceScope fromIface;
      to = common.interfaceScope toIface;
      intent = {
        kind = "core-transit-mesh";
        source = "forwarding-model-transit";
        from = originRefFor fromIface;
        to = originRefFor toIface;
      };
      # Policy authority for this interface-pair accept. The relation label
      # above is topology provenance only; this record is what authorizes
      # the transport.
      transportAuthority = {
        basis = "dedicated-link-isolation";
        provenanceIsAuthority = false;
        from = transitIsolationProof fromIface;
        to = transitIsolationProof toIface;
      };
      relationCardinality = {
        unit = "core-transit-mesh-rule";
        decomposition = "one-rule-per-core-transit-interface-pair";
        decomposed = true;
      };
    }
    // common.relationHandoff {
      inherit relationId direction fromIface toIface;
      action = "accept";
      policyPoint = "core-transit-mesh";
    };

  # FS-270-HDS-010-SDS-010-SMS-010: return traffic is bounded stateful reply
  # traffic, never an independently initiated reverse new flow. The reverse
  # leg carries an established,related connection-state constraint; a
  # state-unqualified reverse accept requires a distinct modeled reverse
  # relation.
  reverseRule = transitIface: uplinkIface: {
    action = "accept";
    fromInterface = uplinkIface.runtimeIfName;
    toInterface = transitIface.runtimeIfName;
    applyTcpMssClamp = false;
    connectionState = "established,related";
    returnRule = true;
  };

  # The upstream-selector health-gates each overlay lane by pinging through the
  # tunnel (ping -I <lane> 1.1.1.1). That ICMP originates from the selector's
  # own fabric address, which is not a tenant prefix, so it needs an explicit
  # enforceable probe rule (trafficType=icmp) in addition to the tenant-prefix
  # handoff rules.
  laneHealthProbeRule = transitIface: uplinkIface:
    {
      action = "accept";
      fromInterface = transitIface.runtimeIfName;
      toInterface = uplinkIface.runtimeIfName;
      applyTcpMssClamp = false;
    } // common.selectorPairAuditWith { trafficType = "icmp"; } "forward" transitIface uplinkIface;

  uplinkPairRules =
    transitIface: uplinkIface:
    if
      uplinkIface.sourceKind == "overlay"
      && delegatedOverlayEgress.exitNodesFor uplinkIface != [ ]
    then
      delegatedOverlayEgress.rulesFor transitIface uplinkIface
      ++ [ (reverseRule transitIface uplinkIface) (laneHealthProbeRule transitIface uplinkIface) ]
    else if uplinkIface.sourceKind == "overlay" then
      common.selectorPairRuleWithSourcePrefixes allTenantPrefixes transitIface uplinkIface
      ++ [ (laneHealthProbeRule transitIface uplinkIface) ]
    else
      common.selectorPairRuleWithSourcePrefixes allTenantPrefixes transitIface uplinkIface;

  meshRules =
    builtins.concatLists (
      builtins.map
        (fromIface:
          builtins.map
            (toIface:
              {
                action = "accept";
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              } // coreTransitAudit fromIface toIface)
            (builtins.filter
              (toIface: toIface.runtimeIfName != fromIface.runtimeIfName)
              admissibleTransitInterfaces))
        admissibleTransitInterfaces
    );

  exitRules =
    builtins.concatLists (
      builtins.map
        (transitIface:
          builtins.concatLists (
            builtins.map
              (uplinkIface: uplinkPairRules transitIface uplinkIface)
              uplinkInterfaces
          ))
        admissibleTransitInterfaces
    );
in
{
  rules = meshRules ++ dnsServicePublicEgressRules ++ exitRules;
  inherit transitAdmission;
}
