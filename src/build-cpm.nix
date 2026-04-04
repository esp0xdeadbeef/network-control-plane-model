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

  forwardingModelAttrs =
    if builtins.isAttrs forwardingModel then
      forwardingModel
    else
      { };

  _validated = validateForwardingModel forwardingModelAttrs;

  meta =
    if builtins.isAttrs (forwardingModelAttrs.meta or null) then
      forwardingModelAttrs.meta
    else
      { };

  marker =
    if builtins.isAttrs (meta.networkForwardingModel or null) then
      meta.networkForwardingModel
    else
      {
        name = "network-forwarding-model";
        schemaVersion = 6;
      };

  enterprise = contractSupport.optionalAttrs (forwardingModelAttrs.enterprise or null);

  cpmData =
    lib.mapAttrsSorted
      (enterpriseName: enterpriseValue:
        let
          enterpriseAttrs =
            if builtins.isAttrs enterpriseValue then
              enterpriseValue
            else
              { };

          sites = contractSupport.optionalAttrs (enterpriseAttrs.site or null);
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
    schemaVersion = marker.schemaVersion or 6;
  };
  data = cpmData;
}
