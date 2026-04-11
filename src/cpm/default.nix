{ lib, helpers, forwardingModel, inventory ? { } }:

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

  buildSiteData =
    import ./build-site-data.nix {
      inherit lib helpers realizationIndex endpointInventoryIndex;
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

  cpm = {
    version = 2;
    data = cpmData;
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
