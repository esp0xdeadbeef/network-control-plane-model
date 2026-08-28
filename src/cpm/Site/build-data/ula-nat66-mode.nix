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

  canonicalPrefix = value:
    let
      canonical = common.ipam.canonicalNetworkPrefix value;
    in
    if canonical == null then value else canonical;

  # ULA owner entries from tenantPrefixOwners
  ownerEntries =
    builtins.filter
      (owner:
        (owner.family or null) == 6
        && isUla6Prefix (owner.dst or null)
        && isNonEmptyString (owner.owner or null))
      (builtins.attrValues tenantPrefixOwners);

  # All ULA prefixes from owners
  allUlaPrefixes = uniqueStrings (builtins.map (owner: canonicalPrefix owner.dst) ownerEntries);

  # Explicit NAT66 selection is the model authority (FS-420). The forwarding
  # model materializes it into each egress node's egressIntent.nat66 from the
  # modeled uplink translation. Overlay egress (for example WireGuard) selects
  # NAT66 there even when the CPM has no physical WAN translation surface.
  explicitNat66ByTarget =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            egress = attrsOrEmpty (runtimeTargets.${targetName}.egressIntent or null);
            nat66 = attrsOrEmpty (egress.nat66 or null);
            sourcePrefixes = uniqueStrings (builtins.map canonicalPrefix (builtins.concatMap
              (uplinkName: listOrEmpty ((attrsOrEmpty (nat66.${uplinkName} or null)).sourcePrefixes or null))
              (builtins.attrNames nat66)));
          in
          {
            name = targetName;
            value = sourcePrefixes;
          })
        (sortedNames runtimeTargets)
    );

  # Find runtime targets with NAT66 enabled
  nat66Targets =
    builtins.filter
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
        in
        (natIntent.families.ipv6 or false) == true || (explicitNat66ByTarget.${targetName} or [ ]) != [ ])
      (sortedNames runtimeTargets);

  # All NAT66 source prefixes from enabled targets
  nat66SourcePrefixes =
    uniqueStrings (builtins.concatMap
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
        in
        (builtins.map canonicalPrefix (listOrEmpty (natIntent.masqueradeSourcePrefixes6 or null)))
        ++ (explicitNat66ByTarget.${targetName} or [ ]))
      nat66Targets);

  # For each ULA prefix with an owner, check if it has NAT66 egress
  ownerForPrefix = prefix:
    let
      matches = builtins.filter (owner: (canonicalPrefix (owner.dst or null)) == prefix) ownerEntries;
    in
    if matches == [ ] then null else builtins.head matches;

  nat66TargetForPrefix = prefix:
    let
      matches = builtins.filter
        (targetName:
          let
            natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
          in
          builtins.elem prefix (builtins.map canonicalPrefix (natIntent.masqueradeSourcePrefixes6 or [ ]))
          || builtins.elem prefix (explicitNat66ByTarget.${targetName} or [ ]))
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
        egress = attrsOrEmpty (runtimeTargets.${targetName}.egressIntent or null);
        nat66 = attrsOrEmpty (egress.nat66 or null);
        uplinks =
          if (natIntent.uplinks or [ ]) != [ ] then
            natIntent.uplinks
          else
            builtins.attrNames nat66;
      in
      [
        {
          mode = "ula-nat66";
          prefix = prefix;
          tenant = owner.netName or null;
          owner = owner.owner;
          source = "tenant-prefix-owner";
          runtimeTarget = targetName;
          inherit uplinks;
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
