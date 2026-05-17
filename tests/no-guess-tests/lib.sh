#!/usr/bin/env bash

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
golden_input_file="${repo_root}/fixtures/passing/golden-no-guessing-base/input.nix"
default_egress_inventory_file="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

status=0

run_case() {
  local name="$1"
  local expected="$2"
  local input_nix="$3"
  local inventory_nix="$4"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  printf '%s\n' "$input_nix" > "${tmp_dir}/input.nix"
  printf '%s\n' "$inventory_nix" > "${tmp_dir}/inventory.nix"

  local stderr_file
  stderr_file="$(mktemp)"

  local expr
  expr="let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${tmp_dir}/input.nix;
    inventory = import ${tmp_dir}/inventory.nix;
  in
    builder { inherit input inventory; }"

  if nix eval --impure --json --expr "${expr}" >/dev/null 2>"${stderr_file}"; then
    echo "FAIL ${name}: evaluation unexpectedly succeeded"
    status=1
  else
    if grep -Fq "${expected}" "${stderr_file}"; then
      echo "PASS ${name}"
    else
      echo "FAIL ${name}: missing expected error"
      echo "expected: ${expected}"
      echo "stderr:"
      cat "${stderr_file}"
      status=1
    fi
  fi

  rm -f "${stderr_file}"
  rm -rf "${tmp_dir}"
  trap - RETURN
}

mutate_once_with_nix() {
  local source_file="$1"
  local op="$2"
  local old_file="$3"
  local new_file="${4:-}"

  local expr
  case "$op" in
    replace)
      expr="
        let
          text = builtins.readFile ${source_file};
          old = builtins.readFile ${old_file};
          new = builtins.readFile ${new_file};
          out = builtins.replaceStrings [ old ] [ new ] text;
        in
        if out == text then
          throw \"mutation failed: replace pattern not found\"
        else
          out
      "
      ;;
    delete)
      expr="
        let
          text = builtins.readFile ${source_file};
          old = builtins.readFile ${old_file};
          out = builtins.replaceStrings [ old ] [ \"\" ] text;
        in
        if out == text then
          throw \"mutation failed: delete pattern not found\"
        else
          out
      "
      ;;
    *)
      echo "unknown mutation op: ${op}" >&2
      return 1
      ;;
  esac

  nix eval --impure --raw --expr "${expr}"
}

mutate_input() {
  local work_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' RETURN

  local current_file="${work_dir}/current.nix"
  cp "${golden_input_file}" "${current_file}"

  while (($# > 0)); do
    local op="$1"
    shift

    case "$op" in
      replace)
        local old="$1"
        local new="$2"
        shift 2

        local old_file="${work_dir}/old.txt"
        local new_file="${work_dir}/new.txt"
        local next_file="${work_dir}/next.nix"

        printf '%s' "${old}" > "${old_file}"
        printf '%s' "${new}" > "${new_file}"
        mutate_once_with_nix "${current_file}" replace "${old_file}" "${new_file}" > "${next_file}"
        mv "${next_file}" "${current_file}"
        ;;
      delete)
        local old="$1"
        shift

        local old_file="${work_dir}/old.txt"
        local next_file="${work_dir}/next.nix"

        printf '%s' "${old}" > "${old_file}"
        mutate_once_with_nix "${current_file}" delete "${old_file}" > "${next_file}"
        mv "${next_file}" "${current_file}"
        ;;
      *)
        echo "unknown mutation op: ${op}" >&2
        return 1
        ;;
    esac
  done

  cat "${current_file}"
  trap - RETURN
  rm -rf "${work_dir}"
}

mutate_inventory() {
  local work_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' RETURN

  local current_file="${work_dir}/current.nix"
  cp "${default_egress_inventory_file}" "${current_file}"

  while (($# > 0)); do
    local op="$1"
    shift

    case "$op" in
      replace)
        local old="$1"
        local new="$2"
        shift 2

        local old_file="${work_dir}/old.txt"
        local new_file="${work_dir}/new.txt"
        local next_file="${work_dir}/next.nix"

        printf '%s' "${old}" > "${old_file}"
        printf '%s' "${new}" > "${new_file}"
        mutate_once_with_nix "${current_file}" replace "${old_file}" "${new_file}" > "${next_file}"
        mv "${next_file}" "${current_file}"
        ;;
      delete)
        local old="$1"
        shift

        local old_file="${work_dir}/old.txt"
        local next_file="${work_dir}/next.nix"

        printf '%s' "${old}" > "${old_file}"
        mutate_once_with_nix "${current_file}" delete "${old_file}" > "${next_file}"
        mv "${next_file}" "${current_file}"
        ;;
      *)
        echo "unknown mutation op: ${op}" >&2
        return 1
        ;;
    esac
  done

  cat "${current_file}"
  trap - RETURN
  rm -rf "${work_dir}"
}

run_case_from_golden() {
  local name="$1"
  local expected="$2"
  shift 2
  run_case "$name" "$expected" "$(mutate_input "$@")" '{}'
}

finish_no_guess_tests() {
  exit "${status}"
}
