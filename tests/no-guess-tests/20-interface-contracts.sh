#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case_from_golden \
  "interface-name-must-be-explicit" \
  "forwardingModel.enterprise.acme.site.ams.nodes.access-1.interfaces.tenant0.interface is required" \
  delete \
  '                  interface = "tenant-a";
'

run_case_from_golden \
  "tenant-interface-missing-tenant" \
  "tenant interface requires explicit tenant" \
  delete \
  '                  tenant = "tenant-a";
'

run_case_from_golden \
  "tenant-interface-requires-explicit-site-attachment" \
  "tenant interface requires explicit site.attachments entry" \
  replace \
  '          attachments = [
            {
              kind = "tenant";
              name = "tenant-a";
              unit = "access-1";
            }
          ];' \
  '          attachments = [ ];'

run_case_from_golden \
  "access-node-missing-explicit-tenant-identity" \
  "access node requires at least one tenant interface with explicit tenant" \
  replace \
  '                tenant0 = {
                  interface = "tenant-a";
                  kind = "tenant";
                  tenant = "tenant-a";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };' \
  '                tenant0 = {
                  interface = "tenant-a";
                  kind = "lan";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };'

run_case_from_golden \
  "overlay-interface-missing-explicit-overlay" \
  "overlay interface requires explicit overlay" \
  delete \
  '                  overlay = "nebula-east-west";
'

run_case_from_golden \
  "wan-interface-missing-explicit-upstream" \
  "wan interface requires explicit upstream" \
  delete \
  '                  upstream = "wan";
'

run_case_from_golden \
  "wan-interface-missing-explicit-link" \
  "wan interface requires explicit link" \
  delete \
  '                  link = "wan-core";
'

finish_no_guess_tests
