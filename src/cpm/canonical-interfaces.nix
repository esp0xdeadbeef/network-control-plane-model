# Canonical interface identity, published by the producer.
#
# WHY HERE
# --------
# A peer renderer (network-renderer-openconfig) maps `canonicalInterfaces[]`, each
# with an explicit identity name and an IANA interface type. It refused to invent
# either, so it rendered nothing for a real site and said so
# (`OC_TYPE_IDENTITY_UNMAPPED`). The field did not exist anywhere: not in a CPM
# compiled from a site intent, not in a CPM compiled from the lab example, not in
# the realization model and not in the realization schema. Every renderer's
# positive test was therefore validated against a hand-written fixture shape
# (`network-realization-model/examples/cpm-result.nix`), which is why the gap was
# invisible from the renderer suites.
#
# The interface identity is a property of the modelled network, so it belongs to
# the producer. A renderer that derived it from `runtimeIfName` (a platform
# string) or from an adapter class (a realization mechanic) would be inventing
# canonical meaning, which FS-310 forbids. This module derives it from the
# control-plane model's own facts instead, and fails closed if a modelled
# interface has no class it can classify.
#
# SHAPE
# -----
# Kept to exactly the fields the peer renderer's rule set maps:
#
#   /identity/name      -> canonical interface name (the runtime interface name)
#   /type/ianaIdentity  -> an IANA ifType identity string
#   /enabled            -> always true; a modelled interface exists, so it is up
#   /canonicalPath      -> the locator, which the renderer treats as metadata
#
# Adding a field here is a contract change: `openconfig-interface-mapping-v1.json`
# must gain a rule for it or the renderer fails with OC_CANONICAL_PATH_UNMAPPED.
{ lib }:
cpm:
let
  enterpriseNames = builtins.attrNames (cpm.data or { });

  sitePairs = builtins.concatMap
    (enterprise:
      let sites = cpm.data.${enterprise} or { }; in
      map (site: { inherit enterprise site; }) (builtins.attrNames sites))
    enterpriseNames;

  # IANA ifType identity, derived from the modelled interface class. Every branch
  # is a recorded fact on the interface, not a platform guess:
  #
  #   providerSession  an upstream session (PPPoE) is a point-to-point interface
  #   overlay          an overlay/tunnel interface
  #   otherwise        a bridge member or veth: an Ethernet-like interface
  #
  # There is deliberately no default branch for an interface that is neither
  # classified nor plainly Ethernet: an unknown class fails closed here rather
  # than being published as Ethernet and silently mis-modelled.
  ianaIdentityFor =
    interface:
    let
      class = interface.interfaceClass or { };
      sourceKind = interface.sourceKind or null;
      adapterClass = interface.adapterClass or null;
      providerSession = (class.providerSession or false) == true;
      isOverlay = sourceKind == "overlay";
      isPpp = providerSession || adapterClass == "pppoe" || adapterClass == "ppp";
    in
    if isPpp then
      "iana-if-type:ppp"
    else if isOverlay then
      # Overlay VPN adapters (nebula/wireguard) are modelled as virtual adapters
      # with `sourceKind = "overlay"` and no `interfaceClass` at all -- measured:
      # the six such interfaces in the residential-testnet HAT intent are
      # `nebula1`, `wg-host128`, `wg-egress`. They are tunnels.
      "iana-if-type:tunnel"
    else if interface ? interfaceClass then
      "iana-if-type:ethernetCsmacd"
    else
      throw "canonical-interfaces: interface '${interface.runtimeIfName or "?"}' has no modelled class (sourceKind/adapterClass/interfaceClass) to classify";

  # The canonical identity of an interface is SITE-WIDE UNIQUE, and that is not
  # the same thing as its platform name. Measured on the neon site: 89 realized
  # interfaces, only 68 distinct `runtimeIfName` and only 51 distinct logical
  # interface keys, because every container reuses `eth0`/`lo`. A flat collection
  # keyed by either would publish duplicates and an OpenConfig consumer would
  # emit several interfaces with one name.
  #
  # So the identity is qualified by its owning runtime target. That is an
  # explicit canonical identity, not a platform device name: a listener that
  # wants the device name reads the segment after the first `/`, and a future
  # per-device canonical shape can carry the target as its own field instead of
  # a qualifier.
  interfaceNameFor =
    targetName: interfaceName:
    let
      name = interfaceName;
    in
    if builtins.isString name && name != "" then
      "${targetName}/${name}"
    else
      throw "canonical-interfaces: interface without a modelled name cannot be published";

  # Deterministic order: enterprise, site, runtime target, then interface name.
  # Two evaluations of the same model must produce the same indices, because the
  # canonical path embeds the index.
  pairs = builtins.sort
    (a: b: (a.key < b.key))
    (builtins.concatMap
      ({ enterprise, site }:
        let
          targets = (cpm.data.${enterprise}.${site}.runtimeTargets or { });
        in
        builtins.concatMap
          (targetName:
            let
              interfaces =
                (targets.${targetName}.effectiveRuntimeRealization.interfaces or { });
            in
            map
              (ifaceName: {
                key = "${enterprise}/${site}/${targetName}/${ifaceName}";
                inherit targetName ifaceName;
                interface = interfaces.${ifaceName};
              })
              (builtins.attrNames interfaces))
          (builtins.attrNames targets))
      sitePairs);
in
builtins.genList
  (index:
    let
      entry = builtins.elemAt pairs index;
    in
    {
      canonicalPath = "/network/data/canonicalInterfaces/${toString index}";
      identity.name = interfaceNameFor entry.targetName entry.ifaceName;
      type.ianaIdentity = ianaIdentityFor entry.interface;
      enabled = true;
    })
  (builtins.length pairs)
