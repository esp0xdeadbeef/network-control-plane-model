#!/usr/bin/env bash
# GAMP-ID: FS-170-HDS-010-SDS-010-SMS-020
# GAMP-ID: SMT-CPM-MODELED-DENY-UNRESOLVED-DIAGNOSTIC-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    system = builtins.currentSystem;
    builder = flake.lib.${system}.build;

    baseInput = import (repoRoot + "/fixtures/passing/minimal-explicit/input.nix");
    baseInventory = import (repoRoot + "/fixtures/passing/minimal-explicit/inventory.nix");
    baseSite = baseInput.enterprise.acme.site.ams;

    relationFor = action: {
      id = "deny-unresolved-client-to-missing-wan";
      inherit action;
      priority = 17;
      trafficType = "dns";
      from = {
        kind = "tenant";
        name = "unresolved-client";
      };
      to = {
        kind = "external";
        name = "missing-wan";
      };
      matches = [
        {
          proto = "udp";
          dstPort = 53;
        }
      ];
    };

    inputWith = action:
      baseInput // {
        enterprise = baseInput.enterprise // {
          acme = baseInput.enterprise.acme // {
            site = baseInput.enterprise.acme.site // {
              ams = baseSite // {
                domains = baseSite.domains // {
                  tenants = [
                    { name = "unresolved-client"; }
                  ];
                  externals = [
                    { name = "missing-wan"; }
                  ];
                };
                communicationContract = baseSite.communicationContract // {
                  relations = [ (relationFor action) ];
                  allowedRelations = [ (relationFor action) ];
                };
              };
            };
          };
        };
      };

    denyBuilt = builder {
      input = inputWith "deny";
      inventory = baseInventory;
    };
    denySite = denyBuilt.control_plane_model.data.acme.ams;
    endpointDiagnostics =
      denySite.policy.endpointBindings.diagnostics.unresolvedDenyEndpoints or [ ];
    forwardingDiagnostics =
      denySite.runtimeTargets.policy-runtime.forwardingIntent.diagnostics.unresolvedDenyEndpoints or [ ];

    diagnosticComplete = diagnostic:
      diagnostic.code == "unresolved-modeled-deny-endpoint"
      && diagnostic.mode == "fail-closed"
      && diagnostic.failClosed == true
      && diagnostic.fallback == "no-renderer-inference"
      && diagnostic.action == "deny"
      && diagnostic.relationId == "deny-unresolved-client-to-missing-wan"
      && diagnostic.priority == 17
      && diagnostic.trafficType == "dns"
      && diagnostic.resolved == false
      && diagnostic.sourceSurface == [ ]
      && diagnostic.destinationSurface == [ ]
      && diagnostic.from.kind == "tenant"
      && diagnostic.from.name == "unresolved-client"
      && diagnostic.to.kind == "external"
      && diagnostic.to.name == "missing-wan";

    tenantDiagnostic =
      builtins.any
        (diagnostic:
          diagnosticComplete diagnostic
          && diagnostic.side == "from"
          && diagnostic.kind == "tenant"
          && diagnostic.name == "unresolved-client"
          && diagnostic.reason == "missing explicit runtime tenant policy binding")
        endpointDiagnostics;
    externalDiagnostic =
      builtins.any
        (diagnostic:
          diagnosticComplete diagnostic
          && diagnostic.side == "to"
          && diagnostic.kind == "external"
          && diagnostic.name == "missing-wan"
          && diagnostic.reason == "missing explicit realized external or WAN policy binding")
        endpointDiagnostics;
    sameForwardingDiagnosticSet =
      builtins.toJSON endpointDiagnostics == builtins.toJSON forwardingDiagnostics;

    allowAttempt =
      builtins.tryEval (
        let
          allowBuilt = builder {
            input = inputWith "allow";
            inventory = baseInventory;
          };
        in
        builtins.deepSeq allowBuilt.control_plane_model.data.acme.ams.policy.endpointBindings true
      );

    checks = {
      endpointDiagnosticCount = builtins.length endpointDiagnostics == 2;
      forwardingDiagnosticCount = builtins.length forwardingDiagnostics == 2;
      inherit tenantDiagnostic externalDiagnostic sameForwardingDiagnosticSet;
      unresolvedDenyDoesNotEmitImplicitRule =
        denySite.runtimeTargets.policy-runtime.forwardingIntent.rules == [ ];
      unresolvedAllowStillFails = allowAttempt.success == false;
    };
  in
    if builtins.all (value: value == true) (builtins.attrValues checks) then
      true
    else
      throw ("fs170 modeled deny unresolved diagnostic checks failed: " + builtins.toJSON checks)
' >/dev/null

echo "PASS fs170-modeled-deny-unresolved-diagnostic"
