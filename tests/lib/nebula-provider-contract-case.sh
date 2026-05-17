#!/usr/bin/env bash
set -euo pipefail

repo_root="$1"
example="$2"
source "${repo_root}/tests/lib/direct-test-guard.sh"

archive_json="$(mktemp)"
violations_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${violations_json}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

example_dir="${labs_path}/examples/${example}"

nix eval --impure --no-warn-dirty --json --expr '
  let
    flake = builtins.getFlake (toString '"${repo_root}"');
    cpmLib = flake.libBySystem.x86_64-linux;
    built = cpmLib.compileAndBuildFromPaths {
      inputPath = "'"${example_dir}/intent.nix"'";
      inventoryPath = "'"${example_dir}/inventory-nixos.nix"'";
    };
    data = built.control_plane_model.data;
  in
    builtins.concatLists (
      map
        (enterpriseName:
          builtins.concatLists (
            map
              (siteName:
                let
                  overlays = data.${enterpriseName}.${siteName}.overlays or {};
                in
                builtins.concatMap
                  (overlayName:
                    let overlay = overlays.${overlayName};
                    in
                    if (overlay.provider or "") == "nebula" && !(overlay ? nebula) then
                      [
                        ("!!!! '"${example}"' "
                          + enterpriseName
                          + "."
                          + siteName
                          + " overlay="
                          + overlayName
                          + " declares provider=nebula but has no provider-specific nebula contract")
                      ]
                    else
                      [ ])
                  (builtins.attrNames overlays))
              (builtins.attrNames data.${enterpriseName}))
          )
        (builtins.attrNames data)
    )
' >"${violations_json}"

violations="$(jq -r '.[]' "${violations_json}")"

if [[ -n "${violations}" ]]; then
  printf '%s\n' "${violations}" >&2
  exit 1
fi

echo "PASS nebula-overlays-have-provider-contract ${example}"
