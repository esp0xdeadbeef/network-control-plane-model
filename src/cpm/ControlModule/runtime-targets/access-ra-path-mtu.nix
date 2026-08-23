{ lib }:

runtimeTargets:

let
  targetNames = lib.sort builtins.lessThan (builtins.attrNames runtimeTargets);

  pppoeClientMtuSources = lib.concatMap
    (targetName:
      let
        target = runtimeTargets.${targetName};
        client = (((target.services or { }).pppoe or { }).client or null);
      in
      lib.optional
        (builtins.isAttrs client && builtins.isInt (client.mtu or null) && client.mtu > 0)
        {
          inherit targetName;
          value = client.mtu;
          interface = client.interface or null;
          runtimeInterface = client.runtimeInterface or null;
        })
    targetNames;

  sourceCount = builtins.length pppoeClientMtuSources;
  uniqueSource = if sourceCount == 1 then builtins.head pppoeClientMtuSources else null;

  bindAdvertisement = advertisement:
    if
      !builtins.isAttrs advertisement
      || (advertisement.enabled or true) == false
      || !builtins.isAttrs (advertisement.delegatedPrefix or null)
    then
      advertisement
    else if uniqueSource != null then
      advertisement // {
        pathMtu = {
          value = uniqueSource.value;
          source = "inventory-runtime-service";
          sourceService = "pppoe-client";
          sourceTarget = uniqueSource.targetName;
          sourceInterface = uniqueSource.interface;
          sourceRuntimeInterface = uniqueSource.runtimeInterface;
        };
      }
    else
      advertisement // {
        pathMtuDiagnostic = {
          traceId = "FS-800-HDS-030-SDS-020-SMS-040";
          code = if sourceCount == 0 then "ACCESS_RA_PATH_MTU_MISSING" else "ACCESS_RA_PATH_MTU_AMBIGUOUS";
          sourceLayer = "inventory";
          message =
            if sourceCount == 0 then
              "Runtime delegated-prefix router advertisement has no explicit PPPoE client MTU source"
            else
              "Runtime delegated-prefix router advertisement has multiple PPPoE client MTU sources and no unique binding";
        };
      };

  # FS-800: bind the PPPoE client MTU provenance onto the *resolved* access
  # advertisements (where delegatedPrefix is already materialized). This must
  # run after resolveAccessAdvertisements; the raw inventory ipv6Ra is an
  # attrset keyed by interface and carries no delegatedPrefix, so binding at
  # the raw-target stage never fires.
  bindAdvertisements = advertisements:
    builtins.mapAttrs
      (_targetName: advertisementSet:
        let
          ipv6Ra = advertisementSet.ipv6Ra or [ ];
        in
        if !builtins.isList ipv6Ra || ipv6Ra == [ ] then
          advertisementSet
        else
          advertisementSet // {
            ipv6Ra = map bindAdvertisement ipv6Ra;
          })
      advertisements;
in
{
  inherit pppoeClientMtuSources;
  inherit bindAdvertisements;
}
