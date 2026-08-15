{ lib
, helpers
, forwardingModel
, inventory ? { }
, validateRuntimeModel ? false
, secretPlatformSubstrate
, emulationSubnets ? [ ]
}:

let
  inherit (helpers)
    forceAll
    requireAttrs
    sortedNames
    ;

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

  inventoryValidation =
    import ./ControlModule/inventory-validation.nix {
      inherit helpers;
    };

  providerAccessRequiredFieldsValidation =
    import ./ControlModule/provider-access-required-fields.nix {
      inherit helpers inventory;
    };

  ipam = import ./ipam.nix { inherit lib; };

  common = import ./Site/build-data/common.nix {
    inherit helpers ipam enterpriseRoot;
  };

  buildSiteData =
    import ./build-site-data.nix {
      inherit lib helpers realizationIndex endpointInventoryIndex inventory enterpriseRoot ipam common emulationSubnets;
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

  cpmDataWithCrossSiteDnsAllowFrom =
    import ./ControlModule/cross-site-dns.nix {
      inherit lib helpers cpmData;
    };

  overlayFieldByName =
    field: data:
    builtins.listToAttrs (
      builtins.concatLists (
        map
          (enterpriseName:
            let enterpriseData = data.${enterpriseName} or { };
            in
            builtins.concatLists (
              map
                (siteName:
                  let siteData = enterpriseData.${siteName} or { };
                  in
                  map
                    (overlayName:
                      let value = siteData.overlays.${overlayName}.${field} or null;
                      in
                      if value == null then [ ] else [ { name = overlayName; inherit value; } ])
                    (builtins.attrNames (siteData.overlays or { })))
                (builtins.attrNames enterpriseData))
          )
          (builtins.attrNames data)
      )
    );

  providerContractsWireguard =
    overlayFieldByName "providerContract" cpmDataWithCrossSiteDnsAllowFrom;

  wgInventory =
    let
      entries = builtins.concatLists (
        map
          (enterpriseName:
            let enterpriseData = cpmDataWithCrossSiteDnsAllowFrom.${enterpriseName} or { };
            in
            builtins.concatLists (
              map
                (siteName:
                  let siteData = enterpriseData.${siteName} or { };
                  in
                  map
                    (overlayName:
                      let
                        overlay = siteData.overlays.${overlayName} or { };
                        nodes = builtins.attrValues (overlay.runtimeNodes or { });
                        ifaces = builtins.filter (s: builtins.isString s && s != "") (
                          map (n: (n.service or { }).interface or null) nodes
                        );
                      in
                      if ifaces == [ ] then [ ] else [ { name = overlayName; value = { interface = builtins.head ifaces; }; } ])
                    (builtins.attrNames (siteData.overlays or { })))
                (builtins.attrNames enterpriseData))
          )
          (builtins.attrNames cpmDataWithCrossSiteDnsAllowFrom)
      );
    in
    builtins.listToAttrs entries;

  secretSourceContract =
    import ./secret-source-contract.nix {
      inherit lib helpers inventory secretPlatformSubstrate;
    };

  cpmWithMediatedCredentials = {
    version = 1;
    data = secretSourceContract.mediateCredentialPaths cpmDataWithCrossSiteDnsAllowFrom;
    providerContracts.wireguard = providerContractsWireguard;
    wgInventory = wgInventory;
  }
  // (
    if builtins.isAttrs (inventory.operationalPrivacyContracts or null) && inventory.operationalPrivacyContracts != { } then
      { operationalPrivacyContracts = inventory.operationalPrivacyContracts; }
    else
      { }
  )
  // (
    if builtins.isAttrs (inventory.failureHandlingContracts or null) && inventory.failureHandlingContracts != { } then
      { failureHandlingContracts = inventory.failureHandlingContracts; }
    else
      { }
  )
  // (
    if builtins.isAttrs (inventory.failureDiagnosticContracts or null) && inventory.failureDiagnosticContracts != { } then
      { failureDiagnosticContracts = inventory.failureDiagnosticContracts; }
    else
      { }
  )
  // (
    if secretSourceContract.secretDeclarations != [ ] then
      { secretDeclarations = secretSourceContract.secretDeclarations; }
    else
      { }
  )
  // (
    if secretSourceContract.secretSources != [ ] then
      { secretSources = secretSourceContract.secretSources; }
    else
      { }
  )
  // (
    if secretSourceContract.sourceBindings != [ ] then
      { sourceBindings = secretSourceContract.sourceBindings; }
    else
      { }
  )
  // {
    secretDeliveryRecords = secretSourceContract.secretDeliveryRecords;
    secretReadiness = secretSourceContract.secretReadiness;
    secretAuthorization = secretSourceContract.secretAuthorization;
    secretPlaintextGuard = secretSourceContract.secretPlaintextGuard;
    secretPolicyBoundary = secretSourceContract.secretPolicyBoundary;
  };

  _validatedRuntimeModel =
    if validateRuntimeModel then
      import ./validate-runtime-model.nix
        {
          inherit helpers;
        }
        {
          cpm = cpmWithMediatedCredentials;
        }
    else
      true;

  _validatedInventory =
    inventoryValidation
      {
        forwardingModel = normalizedInterfaceTags;
        inherit inventory realizationIndex;
      };
in
builtins.seq
  (forceAll [ _validatedRuntimeModel _validatedInventory providerAccessRequiredFieldsValidation ])
  cpmWithMediatedCredentials
