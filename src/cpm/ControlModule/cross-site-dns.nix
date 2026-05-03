{
  lib,
  helpers,
  cpmData,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs sortedNames;
  common = import ./lib/common.nix { inherit helpers; };
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  runtimeTargetEntries =
    builtins.concatLists (
      builtins.map
        (enterpriseName:
          let
            sites = requireAttrs "control_plane_model.data.${enterpriseName}" cpmData.${enterpriseName};
          in
          builtins.concatLists (
            builtins.map
              (siteName:
                let
                  siteData = requireAttrs "control_plane_model.data.${enterpriseName}.${siteName}" sites.${siteName};
                  runtimeTargets =
                    requireAttrs
                      "control_plane_model.data.${enterpriseName}.${siteName}.runtimeTargets"
                      (siteData.runtimeTargets or null);
                in
                builtins.map
                  (targetName: {
                    inherit enterpriseName siteName targetName;
                    target = runtimeTargets.${targetName};
                  })
                  (sortedNames runtimeTargets))
              (sortedNames sites)
          ))
        (sortedNames cpmData)
    );

  entryKey = entry:
    "${entry.enterpriseName}|${entry.siteName}|${entry.targetName}";

  dnsListenersForTarget =
    target:
    let dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
    in uniqueStrings (listOrEmpty (dns.listen or null));

  dnsForwardersForTarget =
    target:
    let dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
    in uniqueStrings (listOrEmpty (dns.forwarders or null));

  interfaceCidrsForTarget =
    target:
    let
      interfaces = attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);
    in
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (ifName:
            let iface = attrsOrEmpty interfaces.${ifName};
            in
            (lib.optional (isNonEmptyString (iface.addr4 or null)) iface.addr4)
            ++ (lib.optional (isNonEmptyString (iface.addr6 or null)) iface.addr6))
          (sortedNames interfaces)
      )
    );

  extraDnsAllowFromByProvider =
    builtins.listToAttrs (
      builtins.map
        (providerEntry: {
          name = entryKey providerEntry;
          value =
            let providerListeners = dnsListenersForTarget providerEntry.target;
            in
            if providerListeners == [ ] then
              [ ]
            else
              uniqueStrings (
                builtins.concatLists (
                  builtins.map
                    (consumerEntry:
                      let consumerForwarders = dnsForwardersForTarget consumerEntry.target;
                      in
                      if
                        entryKey consumerEntry != entryKey providerEntry
                        && lib.any (forwarder: builtins.elem forwarder providerListeners) consumerForwarders
                      then
                        interfaceCidrsForTarget consumerEntry.target
                      else
                        [ ])
                    runtimeTargetEntries
                )
              );
        })
        runtimeTargetEntries
    );

in
builtins.listToAttrs (
  builtins.map
    (enterpriseName: {
      name = enterpriseName;
      value =
        builtins.listToAttrs (
          builtins.map
            (siteName:
              let
                siteData = cpmData.${enterpriseName}.${siteName};
                runtimeTargets = requireAttrs "control_plane_model.data.${enterpriseName}.${siteName}.runtimeTargets" (siteData.runtimeTargets or null);
                updatedRuntimeTargets =
                  builtins.listToAttrs (
                    builtins.map
                      (targetName:
                        let
                          target = runtimeTargets.${targetName};
                          targetServices = attrsOrEmpty (target.services or null);
                          targetDns = attrsOrEmpty (targetServices.dns or null);
                          extraAllowFrom = extraDnsAllowFromByProvider.${"${enterpriseName}|${siteName}|${targetName}"} or [ ];
                          mergedAllowFrom = uniqueStrings ((listOrEmpty (targetDns.allowFrom or null)) ++ extraAllowFrom);
                        in
                        {
                          name = targetName;
                          value =
                            if targetDns == { } || extraAllowFrom == [ ] then
                              target
                            else
                              target // { services = targetServices // { dns = targetDns // { allowFrom = mergedAllowFrom; }; }; };
                        })
                      (sortedNames runtimeTargets)
                  );
              in
              { name = siteName; value = siteData // { runtimeTargets = updatedRuntimeTargets; }; })
            (sortedNames cpmData.${enterpriseName})
        );
    })
    (sortedNames cpmData)
)
