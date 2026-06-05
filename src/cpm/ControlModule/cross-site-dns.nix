{ lib
, helpers
, cpmData
,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs sortedNames;
  common = import ./lib/common.nix { inherit helpers; };
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  mergeDnsAllowFrom = target: extraAllowFrom:
    if !(builtins.hasAttr "services" target) then
      target
    else
      target // {
        services =
          let
            targetServices = attrsOrEmpty (target.services or null);
            targetDns = attrsOrEmpty (targetServices.dns or null);
            mergedAllowFrom = uniqueStrings ((listOrEmpty (targetDns.allowFrom or null)) ++ extraAllowFrom);
          in
          if extraAllowFrom == [ ] || targetDns == { } then
            targetServices
          else
            targetServices // { dns = targetDns // { allowFrom = mergedAllowFrom; }; };
      };

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

  runtimeTargetFactLib = import ./cross-site-dns/runtime-target-facts.nix {
    inherit lib helpers common runtimeTargetEntries entryKey;
  };
  inherit (runtimeTargetFactLib) interfaceCidrsForTarget;
  runtimeTargetFacts = runtimeTargetFactLib.facts;

  overlayServiceDnsAllowFrom =
    import ./cross-site-dns/overlay-service-allow-from.nix {
      inherit
        lib
        helpers
        cpmData
        interfaceCidrsForTarget
        entryKey
        ;
      runtimeTargetEntries = runtimeTargetFacts;
    };

  extraDnsAllowFromByProvider =
    builtins.listToAttrs (
      builtins.map
        (providerEntry: {
          name = providerEntry.key;
          value =
            let providerListeners = providerEntry.dnsListeners;
            in
            if providerListeners == [ ] then
              [ ]
            else
              uniqueStrings (
                builtins.concatLists
                  (
                    builtins.map
                      (consumerEntry:
                        if
                          consumerEntry.key != providerEntry.key
                          && lib.any (forwarder: builtins.elem forwarder providerListeners) consumerEntry.dnsForwarders
                        then
                          consumerEntry.interfaceCidrs
                          ++ consumerEntry.runtimeOriginSourceCidrs
                          ++ consumerEntry.dnsEgressSourceCidrs
                        else
                          [ ])
                      runtimeTargetFacts
                  )
                ++ overlayServiceDnsAllowFrom providerEntry providerListeners
              );
        })
        runtimeTargetFacts
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
                          extraAllowFrom = extraDnsAllowFromByProvider.${"${enterpriseName}|${siteName}|${targetName}"} or [ ];
                        in
                        {
                          name = targetName;
                          value = mergeDnsAllowFrom target extraAllowFrom;
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
