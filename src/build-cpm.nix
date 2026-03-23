# ./src/build-cpm.nix
{ lib }:

{ forwardingModel, inventory ? {} }:

let
  contractSupport = import ./cpm/cpm-contract-support.nix { inherit lib; };

  validateForwardingModel =
    import ./cpm/validate-forwarding-model.nix {
      helpers = contractSupport;
    };

  realizationIndex =
    import ./cpm/realization-index.nix {
      helpers = contractSupport;
      inherit inventory;
    };

  buildSiteData =
    import ./cpm/build-site-data.nix {
      helpers = contractSupport;
      inherit lib realizationIndex;
    };

  _validated = validateForwardingModel forwardingModel;

  marker = forwardingModel.meta.networkForwardingModel;
  enterprise = contractSupport.requireAttrs "forwardingModel.enterprise" (forwardingModel.enterprise or null);

  cpmData =
    lib.mapAttrsSorted
      (enterpriseName: enterpriseValue:
        let
          sites =
            contractSupport.requireAttrs
              "forwardingModel.enterprise.${enterpriseName}.site"
              (enterpriseValue.site or null);
        in
        lib.mapAttrsSorted
          (siteName: site:
            buildSiteData {
              inherit enterpriseName siteName site;
            })
          sites)
      enterprise;
in
builtins.seq _validated {
  version = 1;
  source = "nix";
  inputContract = {
    upstream = marker.name or "network-forwarding-model";
    schemaVersion = marker.schemaVersion or null;
  };
  data = cpmData;
}
