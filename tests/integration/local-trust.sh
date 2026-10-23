#!/usr/bin/env bash
# Exercise the real mkcert/OS trust adapter on an isolated CI runner.
# shellcheck disable=SC2034,SC2016
set -e -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
export CAROOT="$WORK/ca"
cleanup() {
  local status=$?
  trap - EXIT
  mkcert -uninstall >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$ROOT/src/octojoom")
case "$OSTYPE" in linux*) OS_NUMBER=1;; darwin*) OS_NUMBER=2;; msys*|cygwin*) OS_NUMBER=3;; *) exit 1;; esac
mkcert -install
joomlaTLSTrusted "$CAROOT/rootCA.pem"
OCTOJOOM_NON_INTERACTIVE=true
joomlaTLSPrerequisites
mkcert -cert-file "$WORK/leaf.pem" -key-file "$WORK/leaf.key" site.localhost db.localhost
joomlaTLSCertificateValid "$WORK/leaf.pem" "$CAROOT" $'web\tjoomlaalpha\tsite.localhost\ndb\tphpmyadminalpha\tdb.localhost\n'
if joomlaTLSCertificateValid "$WORK/leaf.pem" "$CAROOT" $'web\tjoomlaalpha\tother.localhost\n'; then
  printf 'Incorrect hostname unexpectedly verified.\n' >&2; exit 1
fi
printf 'Native OS trust and hostname validation passed on %s.\n' "$OSTYPE"
