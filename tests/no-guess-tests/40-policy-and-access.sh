#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-NO-GUESS-POLICY-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case_from_golden \
  "missing-canonical-interface-tags" \
  "site.policy.interfaceTags is required" \
  delete \
  '          policy = {
            interfaceTags = {
              tenant0 = "tenant-a";
              uplink0 = "wan";
            };
          };
'

run_case_from_golden \
  "policy-contract-references-unmapped-tenant-tag" \
  "communicationContract references tag 'tenant-a' with no explicit site.policy.interfaceTags mapping" \
  replace \
  '              tenant0 = "tenant-a";' \
  '              tenant0 = "tenant-z";'

run_case_from_golden \
  "external-reference-without-explicit-policy-mapping" \
  "communicationContract references tag 'internet' with no explicit site.policy.interfaceTags mapping" \
  replace \
  '              {
                from = {
                  kind = "tenant";
                  name = "tenant-a";
                };
                to = {
                  kind = "external";
                  name = "wan";
                };
                action = "allow";
              }' \
  '              {
                from = {
                  kind = "tenant";
                  name = "tenant-a";
                };
                to = {
                  kind = "external";
                  name = "internet";
                };
                action = "allow";
              }'

run_case \
  "missing-explicit-access-advertisements-realization" \
  "access runtime target 'access-runtime' requires explicit advertisements realization" \
  "$(cat "${repo_root}/fixtures/passing/default-egress-reachability/input.nix")" \
  "$(mutate_inventory delete \
'        advertisements = {
          dhcp4 = {
            tenant0 = {
              enabled = true;
              pool = {
                start = "10.20.0.100";
                end = "10.20.0.200";
              };
              dnsServers = [ "router-self" ];
              domain = "lan.";
            };
          };
          ipv6Ra = {
            tenant0 = {
              enabled = true;
              rdnss = [ "router-self" ];
              dnssl = [ "lan." ];
            };
          };
        };
')"

run_case \
  "access-dhcp-router-must-match-realized-interface-address" \
  "must match realized tenant interface address '10.20.0.1'" \
  "$(cat "${repo_root}/fixtures/passing/default-egress-reachability/input.nix")" \
  "$(mutate_inventory replace \
'              pool = {
                start = "10.20.0.100";
                end = "10.20.0.200";
              };
              dnsServers = [ "router-self" ];
' \
'              pool = {
                start = "10.20.0.100";
                end = "10.20.0.200";
              };
              router = "10.20.0.254";
              dnsServers = [ "router-self" ];
')"

finish_no_guess_tests
