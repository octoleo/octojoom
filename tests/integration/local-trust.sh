#!/usr/bin/env bash
# Exercise the real mkcert/OS trust adapter on an isolated CI runner.
# shellcheck disable=SC2034,SC2016
set -e -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
export CAROOT="$WORK/ca"
# This job verifies the native OS store. It does not need Java or browser
# profile stores, whose interactive removal can hang an unattended runner.
export TRUST_STORES=system
cleanup() {
  local status=$?
  trap - EXIT
  local fingerprint=''
  if [ -f "$WORK/ca/rootCA.pem" ]; then
    fingerprint=$(openssl x509 -in "$WORK/ca/rootCA.pem" -noout -fingerprint -sha1)
    fingerprint="${fingerprint#*=}"; fingerprint="${fingerprint//:/}"
    case "${OS_NUMBER:-0}" in
      2) sudo -n security delete-certificate -Z "$fingerprint" /Library/Keychains/System.keychain || true;;
      3) certutil.exe -delstore Root "$fingerprint" || true;;
      *) mkcert -uninstall || true;;
    esac
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$ROOT/src/octojoom")
case "$OSTYPE" in linux*) OS_NUMBER=1;; darwin*) OS_NUMBER=2;; msys*|cygwin*) OS_NUMBER=3;; *) exit 1;; esac
# CAROOT is consumed by a native Windows executable, not by Git Bash.
if [ "$OS_NUMBER" = 3 ]; then CAROOT=$(cygpath -w "$WORK/ca"); fi
# Windows deliberately asks for GUI consent when adding a CurrentUser root.
# Seed the disposable elevated runner's machine store through its native CLI,
# then exercise mkcert's already-trusted path and Octojoom's actual trust check.
if [ "$OS_NUMBER" = 3 ]; then
  mkcert -cert-file "$WORK/bootstrap.pem" -key-file "$WORK/bootstrap.key" bootstrap.localhost
  certutil.exe -addstore -f Root "$(cygpath -w "$WORK/ca/rootCA.pem")"
fi
mkcert -install
joomlaTLSTrusted "$WORK/ca/rootCA.pem"
OCTOJOOM_NON_INTERACTIVE=true
joomlaTLSPrerequisites
mkcert -cert-file "$WORK/leaf.pem" -key-file "$WORK/leaf.key" site.localhost db.localhost
joomlaTLSCertificateValid "$WORK/leaf.pem" "$WORK/ca" $'web\tjoomlaalpha\tsite.localhost\ndb\tphpmyadminalpha\tdb.localhost\n'
if joomlaTLSCertificateValid "$WORK/leaf.pem" "$WORK/ca" $'web\tjoomlaalpha\tother.localhost\n'; then
  printf 'Incorrect hostname unexpectedly verified.\n' >&2; exit 1
fi
printf 'Native OS trust and hostname validation passed on %s.\n' "$OSTYPE"
