#!/usr/bin/env bash
# Fail when a tracked file names an internal host, a private address, or a private repository.
# These files are published to GitHub; an internal DNS name is not a secret, but it does not belong
# in public history. Exclude the gitleaks config, which deliberately lists private ranges as secret
# keywords rather than as addresses.
set -euo pipefail

bad=$(git grep -nI -E '(forgejo\.lan|[Pp]robe[.-]?[Kk]it|pg-dev[.]infra|https?://[^[:space:]]*\.lan|192\.168\.|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.)' \
        -- . ':!.gitleaks.toml' 2>/dev/null || true)
if [ -n "$bad" ]; then
    printf '%s\n' "$bad" >&2
    echo "internal address or private repository in a tracked file" >&2
    exit 1
fi
