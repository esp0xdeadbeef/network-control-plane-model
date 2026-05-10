{ }:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];

  rulePairKey = rule:
    builtins.toJSON [
      (rule.fromInterface or "")
      (rule.toInterface or "")
    ];

  rulePriority = rule:
    if builtins.isInt (rule.priority or null) then
      rule.priority
    else
      1000;

  ruleTieBreakKey = rule:
    builtins.toJSON [
      (rule.relationId or "")
      (rule.fromInterface or "")
      (rule.toInterface or "")
      (rule.trafficType or "")
      (rule.action or "")
    ];

  ruleLess = left: right:
    let
      leftPriority = rulePriority left;
      rightPriority = rulePriority right;
    in
    if leftPriority == rightPriority then
      ruleTieBreakKey left < ruleTieBreakKey right
    else
      leftPriority < rightPriority;

  sortForwardingRules = forwarding:
    forwarding
    // {
      rules = builtins.sort ruleLess (listOrEmpty (forwarding.rules or null));
    };

  sortEntry = entry:
    entry
    // {
      value = sortForwardingRules (attrsOrEmpty entry.value);
    };

  checkTarget = entry:
    let
      forwarding = attrsOrEmpty (entry.value or null);
      rules = listOrEmpty (forwarding.rules or null);
      targetName = entry.name or "<unknown>";
      step = state: rule:
        let
          key = rulePairKey rule;
          action = rule.action or null;
          trafficType = rule.trafficType or "any";
          relationId = rule.relationId or "<unnamed>";
          priorBroadAccept = state.broadAcceptByPair.${key} or null;
          isBroadAccept = action == "accept" && trafficType == "any";
          isDeny = action == "deny";
          nextBroadAcceptByPair =
            if isBroadAccept && priorBroadAccept == null then
              state.broadAcceptByPair // { ${key} = { inherit relationId; }; }
            else
              state.broadAcceptByPair;
          violation =
            "target ${targetName}: shadowed deny relation ${relationId} on ${rule.fromInterface or "?"}->${rule.toInterface or "?"} after broad allow relation ${priorBroadAccept.relationId}";
        in
        {
          broadAcceptByPair = nextBroadAcceptByPair;
          violations = state.violations ++ (if isDeny && priorBroadAccept != null then [ violation ] else [ ]);
        };
      result =
        builtins.foldl' step
          {
            broadAcceptByPair = { };
            violations = [ ];
          }
          rules;
    in
    if (forwarding.mode or null) != "explicit-policy-forwarding" || result.violations == [ ] then
      true
    else
      throw "network-control-plane-model: policy deny is unreachable because an earlier broad allow shadows it: ${builtins.concatStringsSep "; " result.violations}";
in
{
  sortEntries = entries: builtins.map sortEntry entries;
  assertNoShadowedPolicyDenies = entries: builtins.all checkTarget entries;
}
