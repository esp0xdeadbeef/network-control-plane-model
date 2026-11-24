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

  # The two source paths this model must reconcile. `cpm.data...overlays` is the
  # source the model publishes; the inventory path below is the projection that
  # silently published nothing on the provider-overlay example.
  overlayProvenanceEntries =
    builtins.concatLists (
      map
        (enterpriseName:
          let sites = cpmData.${enterpriseName} or { };
          in
          builtins.concatLists (
            map
              (siteName:
                let overlays = sites.${siteName}.overlays or { };
                in
                map
                  (overlayName:
                    let
                      inventorySites = inventory.controlPlane.sites or { };
                      inventoryOverlays = (inventorySites.${enterpriseName} or { }).${siteName}.overlays or { };
                      inventoryOverlay = inventoryOverlays.${overlayName} or { };
                    in
                    {
                      inherit enterpriseName siteName overlayName inventoryOverlay;
                      overlay = overlays.${overlayName};
                      cpmPath = "cpm.data.${enterpriseName}.${siteName}.overlays.${overlayName}";
                      inventoryPath = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.overlays.${overlayName}";
                    })
                  (sortedNames overlays))
              (sortedNames sites)))
        (sortedNames cpmData));

  overlayRuntimeInterface =
    overlay:
    let
      nodes = builtins.attrValues (overlay.runtimeNodes or { });
      ifaces = builtins.filter (s: builtins.isString s && s != "") (
        map (node: (node.service or { }).interface or null) nodes
      );
    in
    if ifaces == [ ] then null else builtins.head ifaces;

  overlayCarriesProviderMaterial =
    overlay:
    builtins.isAttrs (overlay.providerContract or null)
    || (builtins.isAttrs (overlay.runtimeNodes or null) && builtins.attrNames (overlay.runtimeNodes or { }) != [ ]);

  overlayProvenanceViolation =
    entry: detail:
    throw "FS-460-HDS-010-SDS-010-SMS-070: overlay '${entry.overlayName}' carries provider material at ${entry.cpmPath} but not at ${entry.inventoryPath}. ${detail} The two sources must agree; the CPM publishes one canonicalOverlays record and must not fall back to an empty projection.";

  _validatedOverlayProvenance =
    forceAll (
      map
        (entry:
          if
            builtins.isAttrs (entry.overlay.providerContract or null)
            && !(builtins.isAttrs (entry.inventoryOverlay.providerContract or null))
          then
            overlayProvenanceViolation entry "The provider contract is present only in the model path."
          else if
            overlayCarriesProviderMaterial entry.overlay
            && overlayRuntimeInterface entry.inventoryOverlay == null
          then
            overlayProvenanceViolation entry "The inventory path yields no runtime interface for an overlay that carries provider material."
          else
            true)
        overlayProvenanceEntries);

  providerContractsWireguardRaw =
    builtins.listToAttrs (
      builtins.concatLists (
        map
          (enterpriseName:
            let sites = inventory.controlPlane.sites.${enterpriseName} or { };
            in
            builtins.concatLists (
              map
                (siteName:
                  let overlays = sites.${siteName}.overlays or { };
                  in
                  map
                    (overlayName:
                      let pc = overlays.${overlayName}.providerContract or null;
                      in
                      if pc == null then [ ] else [ { name = overlayName; value = pc; } ])
                    (builtins.attrNames overlays))
                (builtins.attrNames sites)))
          (builtins.attrNames (inventory.controlPlane.sites or { }))
      )
    );

  wgInventoryRaw =
    builtins.listToAttrs (
      builtins.concatLists (
        map
          (enterpriseName:
            let sites = inventory.controlPlane.sites.${enterpriseName} or { };
            in
            builtins.concatLists (
              map
                (siteName:
                  let overlays = sites.${siteName}.overlays or { };
                  in
                  map
                    (overlayName:
                      let
                        nodes = builtins.attrValues (overlays.${overlayName}.runtimeNodes or { });
                        ifaces = builtins.filter (s: builtins.isString s && s != "") (
                          map (n: (n.service or { }).interface or null) nodes
                        );
                      in
                      if ifaces == [ ] then [ ] else [ { name = overlayName; value = { interface = builtins.head ifaces; }; } ])
                    (builtins.attrNames overlays))
                (builtins.attrNames sites)))
          (builtins.attrNames (inventory.controlPlane.sites or { }))
      )
    );

  providerContractsWireguard = builtins.seq _validatedOverlayProvenance providerContractsWireguardRaw;

  wgInventory = builtins.seq _validatedOverlayProvenance wgInventoryRaw;

  secretSourceContract =
    import ./secret-source-contract.nix {
      inherit lib helpers inventory secretPlatformSubstrate;
    };

  cpmWithMediatedCredentials = {
    version = 1;
    data = secretSourceContract.mediateCredentialPaths cpmDataWithCrossSiteDnsAllowFrom;
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
  (forceAll [ _validatedRuntimeModel _validatedInventory providerAccessRequiredFieldsValidation _validatedOverlayProvenance ])
  cpmWithMediatedCredentials
