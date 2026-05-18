{ helpers }:

{ sitePath, siteAttrs, attachments, domains, runtimeTargets }:

let
  bindingCommon = import ./policy-endpoint-bindings/common.nix { inherit helpers; };
  inherit (bindingCommon) attrsOrEmpty;

  policy = attrsOrEmpty (siteAttrs.policy or null);
  policyInterfaceTags =
    if builtins.isAttrs (policy.interfaceTags or null) then
      policy.interfaceTags
    else
      { };

  contractIndex = import ./policy-endpoint-bindings/contract-index.nix {
    inherit helpers bindingCommon;
  } {
    inherit sitePath siteAttrs domains;
  };

  staticIndex = import ./policy-endpoint-bindings/static-index.nix {
    inherit helpers bindingCommon;
  } {
    inherit sitePath attachments domains;
  };

  runtimeIndex = import ./policy-endpoint-bindings/runtime-index.nix {
    inherit helpers bindingCommon;
  } {
    inherit sitePath runtimeTargets;
  };

  emit = import ./policy-endpoint-bindings/emit.nix {
    inherit helpers bindingCommon;
  };

in
emit ({
  inherit sitePath policyInterfaceTags;
} // contractIndex // staticIndex // runtimeIndex)
