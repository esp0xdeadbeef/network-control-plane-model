{ lib
, helpers
, forwardingModel
, inventory ? { }
, validateRuntimeModel ? false
,
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
      inherit lib helpers realizationIndex endpointInventoryIndex inventory enterpriseRoot ipam common;
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

  cpm = {
    version = 1;
    data = cpmDataWithCrossSiteDnsAllowFrom;
  };

  _validatedRuntimeModel =
    if validateRuntimeModel then
      import ./validate-runtime-model.nix
        {
          inherit helpers;
        }
        {
          inherit cpm;
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
  cpm
