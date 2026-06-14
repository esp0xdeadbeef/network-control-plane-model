# FS-720-HDS-010-SDS-025-SMS-010 Phase 3: endpoint-assignment checker
#
# This checker module validates endpointAssignment records after contract
# emission, covering the three remaining SMS predicates:
#
#   P6: Validate DHCP pool/gateway/reservation data does not conflict with
#       static fixture addresses on the same assignment surface.
#   P8: Validate every record has a non-null bridge attachment surface from
#       runtime targets.
#   P10: Validate contract completeness — all required fields present on every
#        record, no partial or silent-gap records.
#
# Pattern follows ula-nat66-mode.nix / routed-client-gua-mode.nix:
# emits records (validated) and diagnostics list.
#
# CPM stance: Missing or conflicting data is an error, not a defaulting opportunity.
{ helpers
, common
, gampRowId ? "FS-720-HDS-010-SDS-025-SMS-010"
,
}:

{ endpointAssignment ? { }
,
}:

let
  inherit (helpers) isNonEmptyString sortedNames hasAttr;
  inherit (common) attrsOrEmpty cidrContainsAddress;

  # All record keys in endpointAssignment
  recordNames = sortedNames endpointAssignment;

  # Utility: get a record safely
  getRecord = name:
    attrsOrEmpty (endpointAssignment.${name} or null);

  # ---------------------------------------------------------------
  # P8: Bridge attachment surface validation
  #     Every record must carry a non-null bridge field.
  # ---------------------------------------------------------------
  checkBridge = name:
    let
      record = getRecord name;
      bridge = record.bridge or null;
    in
    if isNonEmptyString bridge then
      [ ]
    else
      [{
        endpoint = name;
        code = "missing-bridge";
        message =
          "${gampRowId} (P8): endpoint '${name}' has no bridge attachment "
          + "surface — must have non-null bridge field from runtime targets";
        gampId = gampRowId;
      }];

  p8diagnostics =
    builtins.concatLists (builtins.map checkBridge recordNames);

  # ---------------------------------------------------------------
  # P10: Contract completeness
  #      All required fields present on every record.
  # ---------------------------------------------------------------
  requiredFields = [
    "name" "tenant" "enterprise" "site" "mode" "family"
    "bridge" "owningSubstrate" "namespaceOwner" "gampIds"
  ];

  checkCompleteness = name:
    let
      record = getRecord name;
      mode = record.mode or "";
      isDhcp = builtins.substring 0 4 mode == "dhcp"
            || mode == "reservation-dhcp"
            || mode == "reservation-dhcpv6";
      isStatic = builtins.elem mode [ "static" "static-only" ];
      gampIds = record.gampIds or [ ];

      # Missing top-level required fields
      missingTop = builtins.filter
        (field:
          !(hasAttr field record)
          || (record.${field} or null) == null
          || (builtins.isString (record.${field} or null)
              && record.${field} == ""))
        requiredFields;

      # DHCP sub-record checks
      dhcpRecord = attrsOrEmpty (record.dhcp or null);
      hasDhcpRecord = dhcpRecord != { };
      missingDhcpFields =
        if isDhcp then
          let
            hasServedPrefix4 = isNonEmptyString (dhcpRecord.servedPrefix4 or "");
            hasServedPrefix6 = isNonEmptyString (dhcpRecord.servedPrefix6 or "");
            hasGw4 = isNonEmptyString (dhcpRecord.gw4 or "");
            hasGw6 = isNonEmptyString (dhcpRecord.gw6 or "");
            hasConflict = isNonEmptyString (dhcpRecord.conflict or "");
            hasServedPrefix = hasServedPrefix4 || hasServedPrefix6;
            hasGw = hasGw4 || hasGw6;
          in
          builtins.filter (f: f != null) (
            (if !hasDhcpRecord then [ "dhcp" ] else [ ])
            ++ (if !hasServedPrefix then [ "dhcp.servedPrefix4/6" ] else [ ])
            ++ (if !hasConflict then [ "dhcp.conflict" ] else [ ])
          )
        else
          [ ];

      # Static sub-record checks
      staticRecord = attrsOrEmpty (record.static or null);
      hasStaticRecord = staticRecord != { };
      missingStaticFields =
        if isStatic then
          let
            hasAddress = isNonEmptyString (staticRecord.address or "");
            hasAddress6 = isNonEmptyString (staticRecord.address6 or "");
            hasAddressData = hasAddress || hasAddress6;
          in
          builtins.filter (f: f != null) (
            (if !hasStaticRecord then [ "static" ] else [ ])
            ++ (if !hasAddressData then [ "static.address" ] else [ ])
          )
        else
          [ ];

      # gampIds must contain the trace-chain ID
      missingGampId =
        if builtins.isList gampIds && builtins.elem gampRowId gampIds then
          [ ]
        else
          [ "gampIds missing ${gampRowId}" ];

      allMissing =
        missingTop ++ missingDhcpFields ++ missingStaticFields ++ missingGampId;
    in
    if allMissing != [ ] then
      [{
        endpoint = name;
        code = "incomplete-record";
        message =
          "${gampRowId} (P10): endpoint '${name}' (mode=${mode}) has "
          + "missing/incomplete fields: ${builtins.concatStringsSep ", " allMissing}";
        gampId = gampRowId;
        missingFields = allMissing;
      }]
    else
      [ ];

  p10diagnostics =
    builtins.concatLists (builtins.map checkCompleteness recordNames);

  # ---------------------------------------------------------------
  # P6: DHCP/Static address conflict on same bridge
  # ---------------------------------------------------------------
  # Group records by bridge
  recordsByBridge = builtins.foldl'
    (acc: name:
      let
        record = getRecord name;
        bridge = record.bridge or null;
      in
      if isNonEmptyString bridge then
        acc // {
          ${bridge} =
            (acc.${bridge} or [ ])
            ++ [{ inherit name; inherit record; }];
        }
      else
        acc)
    { }
    recordNames;

  bridgeNames = sortedNames recordsByBridge;

  # For a single bridge, find conflicts between DHCP and static records
  checkBridgeConflict = bridge:
    let
      entries = recordsByBridge.${bridge};

      isDhcpRecord = entry:
        let mode = entry.record.mode or "";
        in builtins.substring 0 4 mode == "dhcp"
        || mode == "reservation-dhcp"
        || mode == "reservation-dhcpv6";

      isStaticRecord = entry:
        let mode = entry.record.mode or "";
        in builtins.elem mode [ "static" "static-only" ];

      dhcpEntries = builtins.filter isDhcpRecord entries;
      staticEntries = builtins.filter isStaticRecord entries;
    in
    if dhcpEntries != [ ] && staticEntries != [ ] then
      builtins.concatMap
        (dhcpEntry:
          let
            dhcp = attrsOrEmpty (dhcpEntry.record.dhcp or null);
            servedPrefix4 = dhcp.servedPrefix4 or "";
            servedPrefix6 = dhcp.servedPrefix6 or "";
            gw4 = dhcp.gw4 or "";
            gw6 = dhcp.gw6 or "";

            # Check each static record for overlap with this DHCP record
            staticConflicts = builtins.filter
              (staticEntry:
                let
                  static = attrsOrEmpty (staticEntry.record.static or null);
                  staticAddr4 = static.address or "";
                  staticGw4 = static.gateway4 or "";
                  staticAddr6 = static.address6 or "";
                  staticGw6 = static.gateway6 or "";
                in
                # Static address equals DHCP gateway
                (isNonEmptyString staticAddr4 && staticAddr4 == gw4)
                # Static address inside DHCP served prefix
                || (isNonEmptyString staticAddr4 && isNonEmptyString servedPrefix4
                    && cidrContainsAddress servedPrefix4 staticAddr4)
                # Static gateway equals DHCP gateway
                || (isNonEmptyString staticGw4 && staticGw4 == gw4)
                # IPv6: static address equals DHCP gateway6
                || (isNonEmptyString staticAddr6 && staticAddr6 == gw6)
                # IPv6: static gateway6 equals DHCP gateway6
                || (isNonEmptyString staticGw6 && staticGw6 == gw6))
              staticEntries;

            dn = builtins.concatStringsSep ", "
              (builtins.map (e: e.name) staticConflicts);
          in
          if staticConflicts != [ ] then
            [{
              endpoint = dhcpEntry.name;
              code = "static-dhcp-conflict";
              message =
                "${gampRowId} (P6): DHCP endpoint '${dhcpEntry.name}' on "
                + "bridge '${bridge}' has address/pool conflict with static "
                + "endpoints: ${dn}";
              gampId = gampRowId;
              inherit bridge;
              conflictingEndpoints =
                builtins.map (e: e.name) staticConflicts;
            }]
          else
            [ ])
        dhcpEntries
    else
      [ ];

  p6diagnostics =
    builtins.concatLists (builtins.map checkBridgeConflict bridgeNames);

  # ---------------------------------------------------------------
  # Aggregate
  # ---------------------------------------------------------------
  diagnostics = p6diagnostics ++ p8diagnostics ++ p10diagnostics;

  result = if diagnostics == [ ] then "PASS" else "FAIL";
in
{
  inherit result diagnostics;
  allDiagnostics = diagnostics;
  # Pass through validated records unchanged
  records = endpointAssignment;
  gampIds = [ gampRowId ];
}
