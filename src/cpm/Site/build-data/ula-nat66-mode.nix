{ helpers
, common
,
}:

{ tenantPrefixOwners ? { }
, runtimeTargets ? { }
,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  isUla6Prefix = value:
    isNonEmptyString value && builtins.match "^[fF][cCdD].*" value != null;

  # ULA owner entries from tenantPrefixOwners
  ownerEntries =
    builtins.filter
      (owner:
        (owner.family or null) == 6
        && isUla6Prefix (owner.dst or null)
        && isNonEmptyString (owner.owner or null))
      (builtins.attrValues tenantPrefixOwners);

  # All ULA prefixes from owners
  allUlaPrefixes = uniqueStrings (builtins.map (owner: owner.dst) ownerEntries);

  # Find runtime targets with NAT66 enabled
  nat66Targets =
    builtins.filter
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
        in
        (natIntent.families.ipv6 or false) == true)
      (sortedNames runtimeTargets);

  # All NAT66 source prefixes from enabled targets
  nat66SourcePrefixes =
    uniqueStrings (builtins.concatMap
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
        in
        listOrEmpty (natIntent.masqueradeSourcePrefixes6 or null))
      nat66Targets);

  # For each ULA prefix with an owner, check if it has NAT66 egress
  ownerForPrefix = prefix:
    let
      matches = builtins.filter (owner: (owner.dst or null) == prefix) ownerEntries;
    in
    if matches == [ ] then null else builtins.head matches;

  nat66TargetForPrefix = prefix:
    let
      matches = builtins.filter
        (targetName:
          let
            natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
          in
          builtins.elem prefix (natIntent.masqueradeSourcePrefixes6 or [ ]))
        nat66Targets;
    in
    if matches == [ ] then null else builtins.head matches;

  # Records for ULA prefixes with NAT66 egress available
  recordsForPrefix =
    prefix:
    let
      owner = ownerForPrefix prefix;
      targetName = nat66TargetForPrefix prefix;
    in
    if owner != null && targetName != null then
      let
        natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
      in
      [
        {
          mode = "ula-nat66";
          prefix = prefix;
          tenant = owner.netName or null;
          owner = owner.owner;
          source = "tenant-prefix-owner";
          runtimeTarget = targetName;
          uplinks = natIntent.uplinks or [ ];
          outputInterfaces = natIntent.masqueradeInterfaces6 or [ ];
        }
      ]
    else
      [ ];

  # Diagnostics for ULA prefixes without NAT66 egress
  diagnosticsForPrefix =
    prefix:
    let
      owner = ownerForPrefix prefix;
      hasNat66Source = builtins.elem prefix nat66SourcePrefixes;
    in
    if owner != null && !hasNat66Source then
      [
        {
          code = "ula-nat66-egress-unavailable";
          mode = "fail-closed";
          prefix = prefix;
          tenant = owner.netName or null;
          owner = owner.owner;
          message = "ULA NAT66 egress is not available for this ULA prefix. No runtime target has NAT66 enabled with this source prefix.";
        }
      ]
    else
      [ ];

  # Also pass through NAT66 diagnostics from runtime targets that are fail-closed
  nat66IntentDiagnostics =
    builtins.concatMap
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
          diags = listOrEmpty ((attrsOrEmpty (natIntent.diagnostics or null)).nat66 or null);
        in
        if diags == [ ] then
          [ ]
        else
          builtins.map
            (diag:
              diag // {
                runtimeTarget = targetName;
                source = "runtimeTargets.*.natIntent.diagnostics.nat66";
              })
            diags)
      (sortedNames runtimeTargets);
in
{
  records = {
    ulaNat66 = builtins.concatLists (builtins.map recordsForPrefix allUlaPrefixes);
  };
  diagnostics = {
    ulaNat66 =
      builtins.concatLists (builtins.map diagnosticsForPrefix allUlaPrefixes)
      ++ nat66IntentDiagnostics;
  };
}
