{ tenantPrefixOwners ? { } }:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];

  routeList =
    iface:
    let routes = attrsOrEmpty (iface.routes or null);
    in
      listOrEmpty (routes.ipv4 or null) ++ listOrEmpty (routes.ipv6 or null);

  delegatedPublicEgressRoutes =
    iface:
    builtins.filter
      (
        route:
        builtins.isAttrs route
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress"
        && (route.policyOnly or false) == true
        && builtins.isString ((attrsOrEmpty (route.intent or null)).exitNode or null)
      )
      (routeList iface);

  exitNodesFor =
    iface:
    builtins.attrNames (
      builtins.listToAttrs (
        map
          (route: {
            name = (attrsOrEmpty (route.intent or null)).exitNode;
            value = true;
          })
          (delegatedPublicEgressRoutes iface)
      )
    );

  sourceEntryForOwner =
    exitNode: key: value:
    let
      parts = builtins.filter (part: builtins.isString part) (builtins.split "\\|" key);
      familyPart = if builtins.length parts >= 1 then builtins.elemAt parts 0 else "";
      prefixPart = if builtins.length parts >= 2 then builtins.elemAt parts 1 else "";
      family = if familyPart == "6" then 6 else 4;
      sourceFile =
        if builtins.isString (value.sourceFile or null) && value.sourceFile != "" then
          value.sourceFile
        else if builtins.match "source:.*" prefixPart != null then
          builtins.substring 7 (builtins.stringLength prefixPart) prefixPart
        else
          null;
      prefix =
        if builtins.isString (value.dst or null) && value.dst != "" then
          value.dst
        else
          prefixPart;
    in
    if (value.owner or null) != exitNode then
      null
    else if sourceFile != null then
      {
        inherit family sourceFile;
        kind = "sourceFile";
      }
    else if builtins.isString prefix && prefix != "" then
      {
        inherit family prefix;
        kind = "static";
      }
    else
      null;

  sourceScopeForExitNode =
    exitNode:
    let
      entries = builtins.filter (entry: entry != null) (
        builtins.attrValues (
          builtins.mapAttrs (sourceEntryForOwner exitNode) tenantPrefixOwners
        )
      );
      staticPrefixes =
        builtins.attrValues (
          builtins.listToAttrs (
            map
              (entry: {
                name = "${builtins.toString entry.family}|${entry.prefix}";
                value = { inherit (entry) family prefix; };
              })
              (builtins.filter (entry: entry.kind == "static") entries)
          )
        );
      sourceFiles =
        builtins.attrNames (
          builtins.listToAttrs (
            map
              (entry: {
                name = entry.sourceFile;
                value = true;
              })
              (builtins.filter (entry: entry.kind == "sourceFile") entries)
          )
        );
    in
    {
      inherit sourceFiles staticPrefixes;
    };

  scopedForwardRule =
    transitIface: uplinkIface: sourceScope: family:
    let
      prefixesForFamily = builtins.filter (prefix: (prefix.family or 4) == family) sourceScope.staticPrefixes;
      sourceAttrs =
        (if prefixesForFamily == [ ] then { } else { sourcePrefixes = prefixesForFamily; })
        // (
          if family == 6 && sourceScope.sourceFiles != [ ] then
            {
              inherit (sourceScope) sourceFiles;
            }
          else
            { }
        );
    in
    if sourceAttrs == { } then
      [ ]
    else
      [
        (
          {
            action = "accept";
            fromInterface = transitIface.runtimeIfName;
            toInterface = uplinkIface.runtimeIfName;
            inherit family;
            intent = {
              kind = "delegated-public-egress";
              source = "tenant-prefix-owner";
              stage = "core-transit-to-provider-overlay";
            };
            applyTcpMssClamp = true;
          }
          // sourceAttrs
        )
      ];

  rulesFor =
    transitIface: uplinkIface:
    builtins.concatLists (
      map
        (
          exitNode:
          let sourceScope = sourceScopeForExitNode exitNode;
          in
            scopedForwardRule transitIface uplinkIface sourceScope 4
            ++ scopedForwardRule transitIface uplinkIface sourceScope 6
        )
        (exitNodesFor uplinkIface)
    );
in
{
  inherit exitNodesFor rulesFor;
}
