{
  lib,
  common,
  helpers,
  overlayProvisioning,
}:
let
  inherit (common) listOrEmpty;
  inherit (helpers) isNonEmptyString;

  peerReturnPrefixes = lib.unique (
    lib.concatMap (
      overlayName:
      (listOrEmpty (overlayProvisioning.${overlayName}.peerTenantPrefixes or null))
      ++ (listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null))
    ) (builtins.attrNames overlayProvisioning)
  );
in
family: lane: via:
let
  viaField = if family == 4 then "via4" else "via6";
  prefixes = builtins.filter (
    prefix:
    (prefix.family or null) == family
    && (isNonEmptyString (prefix.dst or null) || isNonEmptyString (prefix.sourceFile or null))
  ) peerReturnPrefixes;
in
if !isNonEmptyString via then
  [ ]
else
  builtins.map (
    prefix:
    let
      isRuntimePrefix = isNonEmptyString (prefix.sourceFile or null);
    in
    {
      inherit family;
      lane = {
        access = lane.access or null;
        uplink = lane.uplink or null;
      };
      policyOnly = true;
      proto = "internal";
      reason = "policy-table-overlay-return";
      intent = {
        kind = if isRuntimePrefix then "runtime-routed-prefix-return" else "overlay-reachability";
        source = if isRuntimePrefix then "intent-routed-prefix" else "peer-tenant-prefix";
        policyTableComplement = true;
      };
      ${viaField} = via;
    }
    // (if isNonEmptyString (prefix.dst or null) then { inherit (prefix) dst; } else { })
    // (if isNonEmptyString (prefix.sourceFile or null) then { inherit (prefix) sourceFile; } else { })
    // builtins.intersectAttrs {
      delegatedPrefixLength = null;
      perTenantPrefixLength = null;
      slot = null;
      prefixPostfix = null;
      prefixName = null;
    } prefix
    // (if isNonEmptyString (prefix.overlay or null) then { inherit (prefix) overlay; } else { })
    // (if isNonEmptyString (prefix.peerSite or null) then { inherit (prefix) peerSite; } else { })
    // (
      if isNonEmptyString (prefix.tenantName or prefix.tenant or null) then
        {
          tenant = prefix.tenantName or prefix.tenant;
        }
      else
        { }
    )
  ) prefixes
