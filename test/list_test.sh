#!/usr/bin/env bash
# Checks the picker's directory list and order against a fixture. Needs only
# bash and find; Rex isn't involved.
#
#   bash test/list_test.sh

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/sessionizer.sh

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rex-sessionizer-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
w=$tmp/work
mkdir -p "$w/project1" "$w/project2/project2-fe" "$w/project2/project2-be" "$w/zeta"
touch "$w/project1/README.md" "$w/project2/project2-fe/package.json" "$w/project2/.DS_Store"

failed=0

# check LABEL CURRENT EXPECTED...
check() {
    local label=$1 current=$2
    shift 2
    local expected got
    expected=$(printf '%s\n' "$@")
    got=$("$script" --work-dir "$w" --current "$current" --list | sed "s|^$w/||")
    if [[ $got == "$expected" ]]; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        echo "  expected:"; sed 's/^/    /' <<<"$expected"
        echo "  got:";      sed 's/^/    /' <<<"$got"
        failed=1
    fi
}

check "no current session"        ""          project1 project2 zeta
check "current session last"      project1    project2 zeta project1
check "subprojects first"         project2    project2/project2-be project2/project2-fe project1 zeta project2
check "siblings first"            project2-fe project2/project2-be project1 project2 zeta project2/project2-fe
check "unknown session"           nosuch      project1 project2 zeta

exit $failed
