{}:

let
  common = import ./rules/common.nix { };
in
{
  buildAccessRules = import ./rules/access.nix { inherit common; };
  buildCoreRules = import ./rules/core.nix { inherit common; };
  buildDownstreamSelectorRules = import ./rules/downstream-selector.nix { inherit common; };
  buildPolicyRules = import ./rules/policy.nix { inherit common; };
  buildUpstreamSelectorRules = import ./rules/upstream-selector.nix { inherit common; };
}
