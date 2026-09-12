{ lib, ipam, siteOverlays }:

let
  overlayNames = lib.sort lib.lessThan (builtins.attrNames siteOverlays);

  canonicalPrefix = prefix: ipam.canonicalNetworkPrefix prefix;

  overlayMtuSources = lib.concatMap
    (overlayName:
      let
        ov = siteOverlays.${overlayName} or { };
        pc = ov.providerContract or { };
        profile = pc.profile or { };
        generatedPeer = profile.generatedPeer or { };
        mtu = generatedPeer.mtu or null;
        nat = pc.nat or { };
        nat4 = nat.ipv4 or { };
        nat6 = nat.ipv6 or { };
        sourceCidrs4 =
          if builtins.isList (nat4.sourceCidrs or null) then nat4.sourceCidrs else [ ];
        sourceCidrs6 =
          if builtins.isList (nat6.sourceCidrs or null) then nat6.sourceCidrs else [ ];
        prefixes4 = builtins.filter (prefix: prefix != null) (map canonicalPrefix sourceCidrs4);
        prefixes6 = builtins.filter (prefix: prefix != null) (map canonicalPrefix sourceCidrs6);
      in
      if builtins.isInt mtu && mtu > 0 then
        lib.optionals (prefixes4 != [ ] || prefixes6 != [ ]) [
          {
            inherit overlayName mtu prefixes4 prefixes6;
          }
        ]
      else
        [ ])
    overlayNames;

  sourcesByPrefix =
    family:
    lib.foldl'
      (acc: src:
        lib.foldl'
          (inner: prefix:
            inner
            // {
              ${prefix} = (inner.${prefix} or [ ]) ++ [
                {
                  mtu = src.mtu;
                  overlayName = src.overlayName;
                }
              ];
            })
          acc
          src.${family})
      { }
      overlayMtuSources;

  sources4 = sourcesByPrefix "prefixes4";
  sources6 = sourcesByPrefix "prefixes6";

  resolveMtu = sources:
    let
      distinctMtus = lib.unique (map (source: source.mtu) sources);
      overlays = lib.unique (map (source: source.overlayName) sources);
    in
    if distinctMtus == [ ] then
      null
    else if builtins.length distinctMtus == 1 then
      {
        value = builtins.head distinctMtus;
        source = "inventory-overlay";
        sourceService = "wireguard";
        sourceOverlays = overlays;
      }
    else
      {
        diagnostic = {
          traceId = "FS-470-HDS-010-SDS-010-SMS-090";
          code = "ACCESS_OVERLAY_PATH_MTU_AMBIGUOUS";
          sourceLayer = "inventory";
          message =
            "Access subnet maps to multiple WireGuard overlays with different tunnel MTU values: "
            + lib.concatStringsSep ", " (
              map (source: "${source.overlayName}=${toString source.mtu}") sources
            );
        };
      };

  bindDhcp4 = advertisement:
    if !builtins.isAttrs advertisement || (advertisement.enabled or true) == false then
      advertisement
    else if advertisement ? interfaceMtu || advertisement ? pathMtu then
      advertisement
    else
      let
        subnet = canonicalPrefix (advertisement.subnet or "");
        resolved = if subnet == null then null else resolveMtu (sources4.${subnet} or [ ]);
      in
      if resolved == null then
        advertisement
      else if resolved ? diagnostic then
        advertisement // {
          interfaceMtuDiagnostic = resolved.diagnostic;
        }
      else
        advertisement // {
          interfaceMtu = resolved;
        };

  bindIpv6Ra = advertisement:
    if !builtins.isAttrs advertisement || (advertisement.enabled or true) == false then
      advertisement
    else if advertisement ? pathMtu || advertisement ? pathMtuDiagnostic then
      advertisement
    else
      let
        prefixes = if builtins.isList (advertisement.prefixes or null) then advertisement.prefixes else [ ];
        canonicalPrefixes = builtins.filter (prefix: prefix != null) (map canonicalPrefix prefixes);
        resolved =
          if canonicalPrefixes == [ ] then
            null
          else
            let
              perPrefix = map (prefix: resolveMtu (sources6.${prefix} or [ ])) canonicalPrefixes;
              distinctMtus = lib.unique (
                map (contract: contract.value or null) (builtins.filter (contract: contract != null && contract ? value) perPrefix)
              );
              overlays = lib.unique (
                lib.concatMap (contract: contract.sourceOverlays or [ ]) (builtins.filter (contract: contract != null && contract ? value) perPrefix)
              );
              ambiguities = builtins.filter (contract: contract != null && contract ? diagnostic) perPrefix;
            in
            if ambiguities != [ ] then
              { diagnostic = (builtins.head ambiguities).diagnostic; }
            else if distinctMtus == [ ] then
              null
            else if builtins.length distinctMtus == 1 then
              {
                value = builtins.head distinctMtus;
                source = "inventory-overlay";
                sourceService = "wireguard";
                sourceOverlays = overlays;
              }
            else
              {
                diagnostic = {
                  traceId = "FS-470-HDS-010-SDS-010-SMS-090";
                  code = "ACCESS_OVERLAY_PATH_MTU_AMBIGUOUS";
                  sourceLayer = "inventory";
                  message =
                    "Router advertisement advertises prefixes that map to different WireGuard overlay MTU values";
                };
              };
      in
      if resolved == null then
        advertisement
      else if resolved ? diagnostic then
        advertisement // {
          pathMtuDiagnostic = resolved.diagnostic;
        }
      else
        advertisement // {
          pathMtu = resolved;
        };

  bindAdvertisements = advertisements:
    builtins.mapAttrs
      (_targetName: advertisementSet:
        let
          dhcp4 = advertisementSet.dhcp4 or [ ];
          ipv6Ra = advertisementSet.ipv6Ra or [ ];
        in
        advertisementSet
        // {
          dhcp4 = if builtins.isList dhcp4 then map bindDhcp4 dhcp4 else dhcp4;
          ipv6Ra = if builtins.isList ipv6Ra then map bindIpv6Ra ipv6Ra else ipv6Ra;
        })
      advertisements;
in
{
  inherit bindAdvertisements overlayMtuSources;
}
