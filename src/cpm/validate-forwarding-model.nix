{ helpers }:

forwardingModel:

let
  inherit (helpers) forceAll requireAttrs requireList requireStringList sortedNames;
  validationCommon = import ./forwarding-validation/common.nix { inherit helpers; };
  inherit (validationCommon) makeStringSet;

  baseValidator =
    (import ../../invariants/default.nix {
      lib = { attrNamesSorted = sortedNames; };
    }).validateForwardingModelInput;

  interfaceValidation = import ./forwarding-validation/interfaces.nix {
    inherit helpers;
    common = validationCommon;
  };
  communicationContractValidation = import ./forwarding-validation/communication-contract.nix {
    inherit helpers;
    common = validationCommon;
  };
  transportValidation = import ./forwarding-validation/transport.nix {
    common = validationCommon;
  };

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;
      attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      links = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);
      uplinkNameSet = makeStringSet (requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null));
      attachmentLookup = interfaceValidation.attachmentLookupForSite attachments;
    in
    builtins.seq
      (transportValidation.validate sitePath siteAttrs)
      (builtins.seq
        (forceAll (
          map
            (nodeName: interfaceValidation.validateNode sitePath attachmentLookup links uplinkNameSet nodeName nodes.${nodeName})
            (sortedNames nodes)
        ))
        (communicationContractValidation.validate sitePath siteAttrs));

  validateEnterprises = inputAttrs:
    let enterprise = requireAttrs "forwardingModel.enterprise" (inputAttrs.enterprise or null);
    in
    forceAll (
      map
        (enterpriseName:
          let
            enterpriseAttrs = requireAttrs "forwardingModel.enterprise.${enterpriseName}" enterprise.${enterpriseName};
            sites = requireAttrs "forwardingModel.enterprise.${enterpriseName}.site" (enterpriseAttrs.site or null);
          in
          forceAll (map (siteName: validateSite enterpriseName siteName sites.${siteName}) (sortedNames sites)))
        (sortedNames enterprise)
    );

  inputAttrs = requireAttrs "forwardingModel" forwardingModel;
in
builtins.seq (baseValidator inputAttrs) (validateEnterprises inputAttrs)
