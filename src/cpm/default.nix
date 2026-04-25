{ lib, helpers, forwardingModel, inventory ? { } }:

let
  inherit (helpers)
    forceAll
    requireAttrs
    sortedNames
    ;

  isNonEmptyString = value:
    builtins.isString value && value != "";

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  listOrEmpty = value:
    if builtins.isList value then
      value
    else
      [ ];

  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  normalizedForwardingModel =
    import ../normalize-forwarding-model.nix forwardingModel;

  normalizedInterfaceTags =
    import ./normalize-interface-tags.nix {
      forwardingModel = normalizedForwardingModel;
    };

  realizationIndex =
    import ./realization-index.nix {
      inherit helpers inventory;
    };

  endpointInventoryIndex =
    import ./inventory-endpoint-index.nix {
      inherit helpers inventory;
    };

  buildSiteData =
    import ./build-site-data.nix {
      inherit lib helpers realizationIndex endpointInventoryIndex inventory enterpriseRoot;
    };

  enterpriseRoot =
    requireAttrs
      "forwardingModel.enterprise"
      (normalizedInterfaceTags.enterprise or null);

  cpmData =
    builtins.listToAttrs (
      builtins.map
        (enterpriseName:
          let
            enterprisePath = "forwardingModel.enterprise.${enterpriseName}";
            enterpriseValue =
              requireAttrs
                enterprisePath
                enterpriseRoot.${enterpriseName};

            siteRoot =
              requireAttrs
                "${enterprisePath}.site"
                (enterpriseValue.site or null);
          in
          {
            name = enterpriseName;
            value =
              builtins.listToAttrs (
                builtins.map
                  (siteName: {
                    name = siteName;
                    value =
                      buildSiteData {
                        inherit enterpriseName siteName;
                        site = siteRoot.${siteName};
                      };
                  })
                  (sortedNames siteRoot)
              );
          })
        (sortedNames enterpriseRoot)
    );

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
    let
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
    in
    uniqueStrings (listOrEmpty (dns.listen or null));

  dnsForwardersForTarget =
    target:
    let
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
    in
    uniqueStrings (listOrEmpty (dns.forwarders or null));

  interfaceCidrsForTarget =
    target:
    let
      runtime = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (runtime.interfaces or null);
    in
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (ifName:
            let
              iface = attrsOrEmpty interfaces.${ifName};
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
            let
              providerListeners = dnsListenersForTarget providerEntry.target;
            in
            if providerListeners == [ ] then
              [ ]
            else
              uniqueStrings (
                builtins.concatLists (
                  builtins.map
                    (consumerEntry:
                      let
                        consumerForwarders = dnsForwardersForTarget consumerEntry.target;
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

  cpmDataWithCrossSiteDnsAllowFrom =
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
                    runtimeTargets =
                      requireAttrs
                        "control_plane_model.data.${enterpriseName}.${siteName}.runtimeTargets"
                        (siteData.runtimeTargets or null);
                    updatedRuntimeTargets =
                      builtins.listToAttrs (
                        builtins.map
                          (targetName:
                            let
                              target = runtimeTargets.${targetName};
                              targetServices = attrsOrEmpty (target.services or null);
                              targetDns = attrsOrEmpty (targetServices.dns or null);
                              extraAllowFrom =
                                extraDnsAllowFromByProvider.${"${enterpriseName}|${siteName}|${targetName}"} or [ ];
                              mergedAllowFrom =
                                uniqueStrings ((listOrEmpty (targetDns.allowFrom or null)) ++ extraAllowFrom);
                            in
                            {
                              name = targetName;
                              value =
                                if targetDns == { } || extraAllowFrom == [ ] then
                                  target
                                else
                                  target
                                  // {
                                    services =
                                      targetServices
                                      // {
                                        dns =
                                          targetDns
                                          // {
                                            allowFrom = mergedAllowFrom;
                                          };
                                      };
                                  };
                            })
                          (sortedNames runtimeTargets)
                      );
                  in
                  {
                    name = siteName;
                    value =
                      siteData
                      // {
                        runtimeTargets = updatedRuntimeTargets;
                      };
                  })
                (sortedNames cpmData.${enterpriseName})
            );
        })
        (sortedNames cpmData)
    );

  cpm = {
    version = 1;
    data = cpmDataWithCrossSiteDnsAllowFrom;
  };

  _validatedRuntimeModel =
    import ./validate-runtime-model.nix {
      inherit helpers;
    } {
      inherit cpm;
    };

  _validatedInventory =
    import ../validate-inventory.nix {
      inherit lib;
    } {
      inherit inventory cpm;
      forwardingModel = normalizedInterfaceTags;
    };
in
builtins.seq
  (forceAll [ _validatedRuntimeModel _validatedInventory ])
  cpm
