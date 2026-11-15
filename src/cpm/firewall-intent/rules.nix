# `lib` is optional: only the modules that classify by modeled metadata need it,
# and the focused callers that import this builder map (e.g. the FS-270
# post-DNAT continuity fixture) construct no targets at all.
{ lib ? null }:

let
  common = import ./rules/common.nix { };
in
{
  buildAccessRules = import ./rules/access.nix { inherit common; };
  buildCoreRules = import ./rules/core.nix { inherit common; };
  buildDownstreamSelectorRules = import ./rules/downstream-selector.nix { inherit common; };
  buildPolicyRules = import ./rules/policy.nix { inherit common; };
  buildUpstreamSelectorRules = import ./rules/upstream-selector.nix {
    inherit common;
    lib = if lib != null then lib else throw "buildUpstreamSelectorRules requires lib (link-identity parsing)";
  };
  # FS-270-HDS-010-SDS-010-SMS-010: post-DNAT per-hop route/tuple continuity
  # evaluation for translated public-ingress tuples. Consumed with modeled
  # translated-tuple hop chains (public-ingress tuple authority,
  # FS-310-HDS-020-SDS-010-SMS-075 chain).
  evaluatePostDnatContinuity = import ./rules/post-dnat-continuity.nix { inherit common; };
}
