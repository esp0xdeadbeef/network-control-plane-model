{ lib }:

enterprise:

let
  invariants = import ../invariants/default.nix { inherit lib; };

  requireAttrs = path: value:
    if builtins.isAttrs value then
      value
    else
      throw "missing required ${path} attribute set";

  normalizeOverlay = site:
    let
      transport =
        if site ? transport then
          requireAttrs "site.transport" site.transport
        else
          {};

      overlays = transport.overlays or {};
    in
    if builtins.isAttrs overlays || builtins.isList overlays then
      overlays
    else
      throw "site.transport.overlays must be an attribute set or list";

  normalizeTransit = site:
    let
      transit =
        if site ? transit then
          site.transit
        else
          throw "missing explicit site.transit with adjacencies and ordering";
    in
    if invariants.hasExplicitTransit transit then
      transit
    else
      throw "missing explicit site.transit with adjacencies and ordering";

  normalizeSite = site:
    let
      siteAttrs = requireAttrs "site" site;
    in
    {
      transit = normalizeTransit siteAttrs;
      overlay = normalizeOverlay siteAttrs;
    };

  normalizeEnterpriseSites = enterpriseName: ent:
    let
      entAttrs = requireAttrs "enterprise.${enterpriseName}" ent;

      siteRoot =
        if entAttrs ? site then
          requireAttrs "enterprise.${enterpriseName}.site" entAttrs.site
        else
          throw "missing required enterprise.${enterpriseName}.site attribute set";
    in
    lib.mapAttrsSorted
      (_siteName: site: normalizeSite site)
      siteRoot;

  enterpriseAttrs =
    if builtins.isAttrs enterprise then
      enterprise
    else
      throw "missing required forwardingModel.enterprise attribute set";

  inputValidation = invariants.validateEnterpriseInputs enterpriseAttrs;

  cpmData =
    lib.mapAttrsSorted
      (enterpriseName: ent: normalizeEnterpriseSites enterpriseName ent)
      enterpriseAttrs;

  cpmValidation = invariants.validateCPMData cpmData;
in
builtins.seq inputValidation (
  builtins.seq cpmValidation {
    version = 1;
    source = "nix";
    data = cpmData;
  }
)
