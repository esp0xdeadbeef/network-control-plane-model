{ lib }:

{ forwardingModel, inventory ? {} }:

let
  contractSupport = import ./cpm/cpm-contract-support.nix { inherit lib; };

  validateForwardingModel =
    import ./cpm/validate-forwarding-model.nix {
      helpers = contractSupport;
    };

  validateRuntimeModel =
    import ./cpm/validate-runtime-model.nix {
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

  forwardingModelAttrs =
    contractSupport.requireAttrs "forwardingModel" forwardingModel;

  _validated = validateForwardingModel forwardingModelAttrs;

  meta =
    contractSupport.requireAttrs "forwardingModel.meta" (forwardingModelAttrs.meta or null);

  marker =
    contractSupport.requireAttrs
      "forwardingModel.meta.networkForwardingModel"
      (meta.networkForwardingModel or null);

  enterprise =
    contractSupport.requireAttrs "forwardingModel.enterprise" (forwardingModelAttrs.enterprise or null);

  cpmData =
    lib.mapAttrsSorted
      (enterpriseName: enterpriseValue:
        let
          enterpriseAttrs =
            contractSupport.requireAttrs
              "forwardingModel.enterprise.${enterpriseName}"
              enterpriseValue;

          sites =
            contractSupport.requireAttrs
              "forwardingModel.enterprise.${enterpriseName}.site"
              (enterpriseAttrs.site or null);
        in
        lib.mapAttrsSorted
          (siteName: site:
            buildSiteData {
              inherit enterpriseName siteName site;
            })
          sites)
      enterprise;

  cpm = {
    version = 1;
    source = "nix";
    inputContract = {
      upstream = marker.name;
      schemaVersion = marker.schemaVersion;
    };
    data = cpmData;
  };

  _runtimeValidated = validateRuntimeModel { inherit cpm; };
in
builtins.seq _validated (
  builtins.seq _runtimeValidated cpm
)
