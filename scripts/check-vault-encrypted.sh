#!/usr/bin/env bash
# Fail if any of the given files is not encrypted with ansible-vault. Used by
# pre-commit and `make lint` to keep a plain-text vault.yml out of the repo.
#
# Usage: check-vault-encrypted.sh [file ...]
set -euo pipefail

status=0
for file in "$@"; do
  # shellcheck disable=SC2016  # a literal header, not a variable
  if [[ $(head -c 15 "$file") != '$ANSIBLE_VAULT;' ]]; then
    echo "$file is not encrypted. Run: uv run ansible-vault encrypt $file" >&2
    status=1
  fi
done
exit $status
