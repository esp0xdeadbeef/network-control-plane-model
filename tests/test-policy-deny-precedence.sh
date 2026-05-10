#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
labs_root="$(
  nix eval --extra-experimental-features 'nix-command flakes' --impure --raw --expr "
    (builtins.getFlake \"path:${repo_root}\").inputs.network-labs.outPath
  "
)"
example_root="${labs_root}/examples/priority-stability"
bad_input="$(mktemp --suffix=.nix)"
observed_json="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "${bad_input}" "${observed_json}" "${stderr_file}"' EXIT

cat >"${bad_input}" <<EOF
let
  base = import ${example_root}/intent.nix;
  site = base.esp0xdeadbeef.site-stable;
  contract = site.communicationContract;
in
base
// {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    site-stable = site // {
      communicationContract = contract // {
        relations =
          builtins.map
            (relation:
              if (relation.id or null) == "deny-admin-dns-to-wan" then
                relation // { priority = 220; }
              else
                relation)
            contract.relations;
      };
    };
  };
}
EOF

nix eval --extra-experimental-features 'nix-command flakes' --impure --json --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    built = flake.lib.${system}.compileAndBuildFromPaths {
      inputPath = \"${example_root}/intent.nix\";
      inventoryPath = \"${example_root}/inventory-nixos.nix\";
    };
    rules =
      built.control_plane_model.data.esp0xdeadbeef.site-stable.runtimeTargets.\"esp0xdeadbeef-site-stable-s-router-policy\".forwardingIntent.rules;
    indexOf = relationId:
      let
        matches =
          builtins.filter
            (entry:
              (entry.rule.relationId or null) == relationId
              && entry.rule.fromInterface == \"ens5\"
              && entry.rule.toInterface == \"ens3\")
            (builtins.genList (index: { inherit index; rule = builtins.elemAt rules index; }) (builtins.length rules));
      in
        if matches == [ ] then -1 else (builtins.head matches).index;
    denyIndex = indexOf \"deny-admin-dns-to-wan\";
    allowIndex = indexOf \"allow-admin-to-wan\";
  in
    {
      ok = denyIndex >= 0 && allowIndex >= 0 && denyIndex < allowIndex;
      inherit denyIndex allowIndex;
      expected = {
        denyRelation = \"deny-admin-dns-to-wan\";
        allowRelation = \"allow-admin-to-wan\";
        fromInterface = \"ens5\";
        toInterface = \"ens3\";
        order = \"deny index must be lower than broad allow index\";
      };
      observedRules =
        builtins.map
          (rule: {
            action = rule.action or null;
            relationId = rule.relationId or null;
            priority = rule.priority or null;
            trafficType = rule.trafficType or null;
            fromInterface = rule.fromInterface or null;
            toInterface = rule.toInterface or null;
          })
          rules;
    }
" >"${observed_json}"

if ! jq -e '.ok == true' "${observed_json}" >/dev/null; then
  echo "FAIL policy-deny-precedence: priority-stability example did not materialize deny before broad allow" >&2
  jq . "${observed_json}" >&2
  exit 1
fi

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
  in
    flake.lib.${system}.compileAndBuildFromPaths {
      inputPath = \"${bad_input}\";
      inventoryPath = \"${example_root}/inventory-nixos.nix\";
    }
" >/dev/null 2>"${stderr_file}"; then
  echo "FAIL policy-deny-precedence: shadowed DNS deny unexpectedly evaluated" >&2
  echo "expected compile failure for mutated priority-stability example with deny-admin-dns-to-wan priority=220 after allow-admin-to-wan priority=200" >&2
  jq . "${observed_json}" >&2
  exit 1
fi

if ! grep -Fq "shadowed deny relation deny-admin-dns-to-wan" "${stderr_file}"; then
  echo "FAIL policy-deny-precedence: expected shadowed deny error" >&2
  echo "expected substring: shadowed deny relation deny-admin-dns-to-wan" >&2
  echo "observed stderr:" >&2
  cat "${stderr_file}" >&2
  exit 1
fi

echo "PASS policy-deny-precedence"
