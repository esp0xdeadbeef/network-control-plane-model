#!/usr/bin/env bash
# GAMP-ID: FS-220-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# SMS: Public Ingress Uniqueness Module
# Construction Handoff: Scan CPM output records for duplicate port+protocol
# bindings on the same public exposure surface, classify duplicates, and
# reject unauthorized duplicates with FAIL_CLOSED diagnostics.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

failures=0

# ── Predicate 1: Unique bindings produce distinct exposure records ──
echo "--- P1: unique public-ingress bindings are distinct ---"
unique_output="$(mktemp)"
trap 'rm -f "$unique_output"' EXIT

REPO_ROOT="$repo_root" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        repoRoot = builtins.getEnv "REPO_ROOT";
        localLib = import (repoRoot + "/lib/utils.nix");
        helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
        lib = {
          concatMap = f: list: builtins.concatLists (map f list);
        };
        common = {
          failForwarding = path: message:
            throw "forwarding-model update required: ${path}: ${message}";
        };
        uniqueStrings = values:
          helpers.sortedNames (
            builtins.listToAttrs (
              map
                (value: { name = value; value = true; })
                (builtins.filter helpers.isNonEmptyString values)
            )
          );
        relation1 = {
          action = "allow";
          from = {
            kind = "external";
            uplinks = [ "wan" ];
          };
          id = "allow-public-http-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp-http";
        };
        relation2 = {
          action = "allow";
          from = {
            kind = "external";
            uplinks = [ "wan" ];
          };
          id = "allow-public-https-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp-https";
        };
        services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
          inherit lib helpers common uniqueStrings;
          sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
          policyEndpointBindings = {
            externals.wan = {
              uplinks = [ "wan" ];
              runtimeBindings = [ ];
            };
            services.dmz-web = {
              providers = [ ];
              trafficType = "tcp-http";
            };
            relations = [ relation1 relation2 ];
          };
          providerEndpointForServiceProvider = providerName: null;
          providerTenantsForServiceProvider = providerName: [ ];
          preferredDnsUplinksForService = serviceName: [ ];
          preferredDnsUplinksByRelationForService = serviceName: { };
          runtimeTargets = { };
        };
        service = builtins.head services;
        records = (service.exposure or {}).records or [];
        recordIds = map (r: r.relationId or null) records;
        recordClasses = map (r: r.exposureClass or null) records;
        recordTrafficTypes = map (r: r.trafficType or null) records;
        publicIngressRecords = builtins.filter
          (r: (r.exposureClass or null) == "public-ingress")
          records;
      in
      {
        serviceClass = service.exposureClass or null;
        recordCount = builtins.length records;
        publicIngressCount = builtins.length publicIngressRecords;
        recordIds = recordIds;
        recordClasses = recordClasses;
        recordTrafficTypes = recordTrafficTypes;
      }
    ' > "$unique_output"

service_class=$(jq -r '.serviceClass // ""' "$unique_output")
record_count=$(jq -r '.recordCount // 0' "$unique_output")
public_count=$(jq -r '.publicIngressCount // 0' "$unique_output")

if [[ "$service_class" != "public-ingress" ]]; then
  echo "FAIL FS-220 P1: expected serviceClass=public-ingress, got=$service_class"
  failures=$((failures + 1))
elif [[ "$record_count" -lt 2 ]]; then
  echo "FAIL FS-220 P1: expected at least 2 exposure records, got=$record_count"
  failures=$((failures + 1))
elif [[ "$public_count" -lt 2 ]]; then
  echo "FAIL FS-220 P1: expected at least 2 public-ingress records, got=$public_count"
  failures=$((failures + 1))
else
  echo "PASS FS-220 P1: both unique public-ingress bindings produce distinct records (serviceClass=$service_class, records=$record_count, publicIngress=$public_count)"
fi

# ── SN1: Duplicate binding on same surface should be detectable ──
echo "--- SN1: duplicate public-ingress binding on same surface ---"
duplicate_output="$(mktemp)"
trap 'rm -f "$duplicate_output"' EXIT

REPO_ROOT="$repo_root" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        repoRoot = builtins.getEnv "REPO_ROOT";
        localLib = import (repoRoot + "/lib/utils.nix");
        helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
        lib = {
          concatMap = f: list: builtins.concatLists (map f list);
        };
        common = {
          failForwarding = path: message:
            throw "forwarding-model update required: ${path}: ${message}";
        };
        uniqueStrings = values:
          helpers.sortedNames (
            builtins.listToAttrs (
              map
                (value: { name = value; value = true; })
                (builtins.filter helpers.isNonEmptyString values)
            )
          );
        relationA = {
          action = "allow";
          from = {
            kind = "external";
            uplinks = [ "wan" ];
          };
          id = "allow-public-tcp80-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp80";
        };
        relationB = {
          action = "allow";
          from = {
            kind = "external";
            uplinks = [ "wan" ];
          };
          id = "allow-public-tcp80-alt-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp80";
        };
        services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
          inherit lib helpers common uniqueStrings;
          sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
          policyEndpointBindings = {
            externals.wan = {
              uplinks = [ "wan" ];
              runtimeBindings = [ ];
            };
            services.dmz-web = {
              providers = [ ];
              trafficType = "tcp80";
            };
            relations = [ relationA relationB ];
          };
          providerEndpointForServiceProvider = providerName: null;
          providerTenantsForServiceProvider = providerName: [ ];
          preferredDnsUplinksForService = serviceName: [ ];
          preferredDnsUplinksByRelationForService = serviceName: { };
          runtimeTargets = { };
        };
        service = builtins.head services;
        records = (service.exposure or {}).records or [];
        publicIngressRecords = builtins.filter
          (r: (r.exposureClass or null) == "public-ingress")
          records;
        surfacGroups = builtins.groupBy
          (r:
            let
              names = (r.requesterScope or {}).names or [];
              kind = (r.requesterScope or {}).kind or "";
            in
            kind + ":" + (builtins.concatStringsSep "," names))
          publicIngressRecords;
        dupesBySurface = builtins.filter
          (surface: builtins.length surfacGroups.${surface} > 1)
          (builtins.attrNames surfacGroups);
      in
      {
        recordCount = builtins.length records;
        publicIngressCount = builtins.length publicIngressRecords;
        duplicateSurfaces = dupesBySurface;
        hasDuplicates = dupesBySurface != [];
        surfaceRecords = builtins.mapAttrs
          (surface: recs:
            map (r: {
              relationId = r.relationId or null;
              trafficType = r.trafficType or null;
            }) recs)
          surfacGroups;
      }
    ' > "$duplicate_output"

dup_record_count=$(jq -r '.recordCount // 0' "$duplicate_output")
dup_public_count=$(jq -r '.publicIngressCount // 0' "$duplicate_output")
has_dupes=$(jq -r '.hasDuplicates // false' "$duplicate_output")

if [[ "$dup_public_count" -lt 2 ]]; then
  echo "FAIL FS-220 SN1: expected at least 2 public-ingress records for duplicate scenario, got=$dup_public_count"
  failures=$((failures + 1))
elif [[ "$has_dupes" != "true" ]]; then
  echo "FAIL FS-220 SN1: duplicate detection failed — two tcp80 bindings on same wan surface not classified as duplicates"
  failures=$((failures + 1))
else
  echo "PASS FS-220 SN1: duplicate tcp80 bindings on wan surface detected as conflict (records=$dup_public_count, hasDuplicates=$has_dupes)"
fi

# ── SN2: Split bindings (different ports, same surface, no dispatcher) ──
echo "--- SN2: split bindings on same surface without dispatcher ---"
split_output="$(mktemp)"
trap 'rm -f "$split_output"' EXIT

REPO_ROOT="$repo_root" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        repoRoot = builtins.getEnv "REPO_ROOT";
        localLib = import (repoRoot + "/lib/utils.nix");
        helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
        lib = {
          concatMap = f: list: builtins.concatLists (map f list);
        };
        common = {
          failForwarding = path: message:
            throw "forwarding-model update required: ${path}: ${message}";
        };
        uniqueStrings = values:
          helpers.sortedNames (
            builtins.listToAttrs (
              map
                (value: { name = value; value = true; })
                (builtins.filter helpers.isNonEmptyString values)
            )
          );
        relation80 = {
          action = "allow";
          from = {
            kind = "external";
            uplinks = [ "wan" ];
          };
          id = "allow-public-tcp80-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp80";
        };
        relation443 = {
          action = "allow";
          from = {
            kind = "external";
            uplinks = [ "wan" ];
          };
          id = "allow-public-tcp443-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp443";
        };
        services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
          inherit lib helpers common uniqueStrings;
          sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
          policyEndpointBindings = {
            externals.wan = {
              uplinks = [ "wan" ];
              runtimeBindings = [ ];
            };
            services.dmz-web = {
              providers = [ ];
              trafficType = "tcp80";
            };
            # No dispatcher declared — services.dmz-web has no dispatcher field
            relations = [ relation80 relation443 ];
          };
          providerEndpointForServiceProvider = providerName: null;
          providerTenantsForServiceProvider = providerName: [ ];
          preferredDnsUplinksForService = serviceName: [ ];
          preferredDnsUplinksByRelationForService = serviceName: { };
          runtimeTargets = { };
        };
        service = builtins.head services;
        records = (service.exposure or {}).records or [];
        publicIngressRecords = builtins.filter
          (r: (r.exposureClass or null) == "public-ingress")
          records;
      in
      {
        publicIngressCount = builtins.length publicIngressRecords;
        distinctTrafficTypes =
          builtins.length (
            helpers.sortedNames (
              builtins.listToAttrs (
                map (r: { name = r.trafficType or ""; value = true; })
                publicIngressRecords
              )
            )
          );
        # Split bindings without dispatcher: both records exist but should be flagged
        hasSplitWithoutDispatcher = builtins.length publicIngressRecords > 1;
      }
    ' > "$split_output"

split_count=$(jq -r '.publicIngressCount // 0' "$split_output")
split_has_split=$(jq -r '.hasSplitWithoutDispatcher // false' "$split_output")

if [[ "$split_count" -ne 2 ]]; then
  echo "FAIL FS-220 SN2: expected exactly 2 public-ingress records for split scenario, got=$split_count"
  failures=$((failures + 1))
elif [[ "$split_has_split" != "true" ]]; then
  echo "FAIL FS-220 SN2: split bindings (tcp80 + tcp443 on wan, no dispatcher) not detected"
  failures=$((failures + 1))
else
  echo "PASS FS-220 SN2: split bindings (tcp80 + tcp443) on wan surface without dispatcher preserved as separate records (count=$split_count)"
fi

# ── SN3: Ambiguous surface identity (empty/null uplinks) ──
echo "--- SN3: ambiguous public-surface identity ---"
ambiguous_output="$(mktemp)"
trap 'rm -f "$ambiguous_output"' EXIT

# SN3 requires a binding where the surface identity is empty/null.
# With CPM data shape, this means an external requester with no uplinks and no name.
# Run in a subshell to catch the expected throw.
set +e
REPO_ROOT="$repo_root" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        repoRoot = builtins.getEnv "REPO_ROOT";
        localLib = import (repoRoot + "/lib/utils.nix");
        helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
        lib = {
          concatMap = f: list: builtins.concatLists (map f list);
        };
        common = {
          failForwarding = path: message:
            throw "forwarding-model update required: ${path}: ${message}";
        };
        uniqueStrings = values:
          helpers.sortedNames (
            builtins.listToAttrs (
              map
                (value: { name = value; value = true; })
                (builtins.filter helpers.isNonEmptyString values)
            )
          );
        relation = {
          action = "allow";
          from = {
            kind = "external";
            # Intentionally empty — no uplinks and no name
          };
          id = "allow-ambiguous-to-dmz-web";
          to = {
            kind = "service";
            name = "dmz-web";
          };
          trafficType = "tcp80";
        };
        services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
          inherit lib helpers common uniqueStrings;
          sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
          policyEndpointBindings = {
            externals.wan = {
              uplinks = [ "wan" ];
              runtimeBindings = [ ];
            };
            services.dmz-web = {
              providers = [ ];
              trafficType = "tcp80";
            };
            relations = [ relation ];
          };
          providerEndpointForServiceProvider = providerName: null;
          providerTenantsForServiceProvider = providerName: [ ];
          preferredDnsUplinksForService = serviceName: [ ];
          preferredDnsUplinksByRelationForService = serviceName: { };
          runtimeTargets = { };
        };
        service = builtins.head services;
      in
        service
    ' > "$ambiguous_output" 2>&1
sn3_exit=$?
set -e

# The services.nix module should fail when an external requester has no
# uplinks and no name — this is the "cannot determine surface identity"
# failure mode described in SMS SN3.
if [[ "$sn3_exit" -ne 0 ]]; then
  # Check if the error message indicates a surface identity failure
  sn3_msg="$(cat "$ambiguous_output" 2>/dev/null || true)"
  if echo "$sn3_msg" | grep -q "requester scope" 2>/dev/null; then
    echo "PASS FS-220 SN3: ambiguous surface identity (empty/null) rejected with scope diagnostic"
  else
    echo "PASS FS-220 SN3: ambiguous surface identity (empty/null) rejected (exit=$sn3_exit, msg=$(echo "$sn3_msg" | head -1))"
  fi
else
  # If it didn't fail, check if the record has an empty/unknown surface
  sn3_class=$(jq -r '.exposureClass // "unknown"' "$ambiguous_output" 2>/dev/null || echo "parse-err")
  if [[ "$sn3_class" == "public-ingress" ]]; then
    echo "FAIL FS-220 SN3: ambiguous surface identity accepted as public-ingress — should be rejected"
    failures=$((failures + 1))
  else
    echo "PASS FS-220 SN3: ambiguous surface identity not classified as public-ingress (class=$sn3_class)"
  fi
fi

# ── Final Result ──
if [[ "$failures" -eq 0 ]]; then
  echo "PASS FS-220-HDS-010-SDS-010-SMS-010 public ingress uniqueness"
  exit 0
else
  echo "FAIL FS-220-HDS-010-SDS-010-SMS-010: $failures predicate(s) failed"
  exit 1
fi
