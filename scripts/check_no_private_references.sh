#!/usr/bin/env bash
# =====================================================================================
# Guard against committing customer or environment-specific references
# =====================================================================================
# This project is meant to be shareable. Anything identifying a specific customer, account or
# internal environment must not be in it — and once committed, it is in the history for good
# even if a later commit removes it. So the check is mechanical.
#
# Extend PATTERNS with anything specific to your own environment before sharing a fork.
set -uo pipefail

PATTERNS=(
    # Account identifiers: a real Snowflake account locator or org-account name.
    #
    # ANCHORED ON WORD BOUNDARIES, which matters more than it looks. Unanchored, this matches
    # inside hexadecimal — a UUID like 9042cc031122 contains "cc03112", so every synthetic
    # UUID in the seeds tripped it. A locator appears as a standalone token, never embedded
    # in a longer hex run, so the boundaries remove the false positives without weakening it.
    '\b[A-Za-z]{2,4}[0-9]{5}\b'
    # Environment-prefixed database names of the form PROD__SOMETHING__SOMETHING.
    '(PROD|DEV|STAGING|UAT)__[A-Z_]+__[A-Z_]+'
    # Service accounts belonging to a specific deployment.
    'service_[a-z_]+__u_role'
    # Personal or internal email domains. example.com and example.net are reserved for
    # documentation and are the only ones this project should contain.
    '@(?!example\.(com|net))[a-z0-9-]+\.(com|net|io|ai|co\.uk)'
)

DESCRIPTIONS=(
    "Snowflake account locator"
    "environment-prefixed database name"
    "deployment-specific service role"
    "non-example email domain"
)

# Only search tracked files, and skip this script (which necessarily contains the patterns).
FILES=$(git ls-files | grep -v 'scripts/check_no_private_references.sh' || true)
[ -z "$FILES" ] && exit 0

FAILED=0
for i in "${!PATTERNS[@]}"; do
    if command -v rg >/dev/null 2>&1; then
        HITS=$(echo "$FILES" | xargs rg --pcre2 --no-heading --line-number "${PATTERNS[$i]}" 2>/dev/null || true)
    else
        # grep -P is unavailable on macOS, so a lookahead-dependent pattern is skipped rather
        # than silently producing a false pass.
        #
        # BE AWARE OF WHAT THIS MEANS: a pattern skipped here still runs in CI, where ripgrep
        # is present. A check that never executes on the maintainer's machine is a check whose
        # first real run is on a pull request — which is exactly how this script came to have a
        # pattern that matched every UUID in the seed data. Keep patterns POSIX-compatible
        # where you can, so local and CI behave the same.
        if [[ "${PATTERNS[$i]}" == *'(?!'* ]]; then
            echo "note: skipping ${DESCRIPTIONS[$i]} check (needs ripgrep or grep -P)"
            continue
        fi
        HITS=$(echo "$FILES" | xargs grep -nE "${PATTERNS[$i]}" 2>/dev/null || true)
    fi

    if [ -n "$HITS" ]; then
        echo "FAIL: possible ${DESCRIPTIONS[$i]} found:"
        # No pipe into head: `set -o pipefail` plus head closing the pipe early turns a
        # successful report into a "write error: Broken pipe" and an unhelpful exit code.
        printf '%s\n' "$(echo "$HITS" | awk 'NR<=20')"
        echo
        FAILED=1
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "This repository is intended to be shareable. Remove the references above."
    echo "If a match is a false positive, refine the pattern in this script."
    exit 1
fi

echo "No private references found."
