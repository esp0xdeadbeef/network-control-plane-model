{ lib }:

enterprise:

let
  deriveTransit = import ./derive-transit.nix { inherit lib; };
  validateTransit = import ./validate-transit.nix { inherit lib; };

  hasExplicitTransit = transit:
    builtins.isAttrs transit
    && builtins.isList (transit.adjacencies or null)
    && builtins.isList (transit.ordering or null);

  normalizeTransit = site:
    let
      transit = site.transit or null;
      _ =
        if hasExplicitTransit transit then
          null
        else
          validateTransit site;
    in
    if hasExplicitTransit transit then
      transit
    else
      deriveTransit site;

  normalizeOverlay = site:
    let
      transport = site.transport or {};
      overlays = transport.overlays or {};
    in
    if builtins.isAttrs overlays || builtins.isList overlays then
      overlays
    else
      {};

  normalizeSite = site: {
    transit = normalizeTransit site;
    overlay = normalizeOverlay site;
  };

  normalizeEnterpriseSites = ent:
    let
      siteRoot =
        if builtins.isAttrs ent.site or null then
          ent.site
        else
          {};
    in
    lib.mapAttrsSorted
      (_: site: normalizeSite site)
      siteRoot;

  cpmData =
    lib.mapAttrsSorted
      (_: ent: normalizeEnterpriseSites ent)
      enterprise;

  # NEW: CPM schema validation
  validateCPM = data:
    let
      validateSite = site:
        let
          transit = site.transit or {};
        in
        if !(builtins.isAttrs transit) then
          throw "CPM validation error: transit must be an attribute set"
        else if !(builtins.isList (transit.adjacencies or null)) then
          throw "CPM validation error: transit.adjacencies must be a list"
        else if !(builtins.isList (transit.ordering or null)) then
          throw "CPM validation error: transit.ordering must be a list"
        else
          true;

      validateSites = sites:
        builtins.mapAttrs (_: validateSite) sites;

      validateEnterprises =
        builtins.mapAttrs (_: validateSites) data;
    in
    validateEnterprises;

  _ = validateCPM cpmData;

in
{
  version = 1;
  source = "nix";
  data = cpmData;
}
