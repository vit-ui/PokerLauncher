#!/usr/bin/env bash
set -euo pipefail

# Protect the default branch from deletion and non-fast-forward updates.
zero="0000000000000000000000000000000000000000"

while read -r local_ref local_oid remote_ref remote_oid; do
    [[ "$remote_ref" != "refs/heads/master" ]] && continue

    if [[ "$local_oid" == "$zero" ]]; then
        echo "Blocked: deleting master is disabled. If intentional, use git push --no-verify." >&2
        exit 1
    fi

    if [[ "$remote_oid" != "$zero" ]] && git cat-file -e "$remote_oid" 2>/dev/null; then
        if ! git merge-base --is-ancestor "$remote_oid" "$local_oid"; then
            echo "Blocked: this would force-push master. If intentional, use git push --force --no-verify." >&2
            exit 1
        fi
    fi
done
