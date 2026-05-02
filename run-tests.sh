#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

find "${repo_root}/tests" -maxdepth 1 -type f -name 'test-*.sh' -print0 \
  | sort -z \
  | xargs -0 -n1 bash
