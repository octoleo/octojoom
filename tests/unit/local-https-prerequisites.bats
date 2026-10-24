#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  OCTOJOOM_NON_INTERACTIVE=false
  OS_NUMBER=1
  TLS_MANAGER=apt-get
  TLS_TOOLS_READY=false
  TLS_TRUST_READY=true
  TLS_INSTALL_STATUS=0
  TLS_INSTALL_POPULATES=true
  # Every package manager and trust operation is a function stub. Even on a
  # runner with these tools installed, no host packages or trust stores change.
  command() {
    if [ "${1:-}" = -v ]; then
      case "${2:-}" in
        mkcert|openssl) [ "$TLS_TOOLS_READY" = true ]; return $?;;
        apt-get|dnf|brew|choco) [ "$TLS_MANAGER" = "$2" ]; return $?;;
        cygpath) return 1;;
      esac
    fi
    builtin command "$@"
  }
  cliSudo() { printf 'sudo %s\n' "$*" >> "$SANDBOX/package-commands"; "$@"; }
  apt-get() { tls_package_manager apt-get "$@"; }
  dnf() { tls_package_manager dnf "$@"; }
  brew() { tls_package_manager brew "$@"; }
  choco() { tls_package_manager choco "$@"; }
  mkcert() {
    case "$1" in
      -CAROOT) printf '%s\n' "$SANDBOX/local-ca";;
      -install) printf 'install\n' >> "$SANDBOX/trust-commands"; TLS_TRUST_READY=true;;
      *) return 1;;
    esac
  }
  joomlaTLSTrusted() { [ "$TLS_TRUST_READY" = true ]; }
}

tls_package_manager() {
  printf '%s\n' "$*" >> "$SANDBOX/package-commands"
  [ "$TLS_INSTALL_STATUS" -eq 0 ] || return "$TLS_INSTALL_STATUS"
  if [ "${2:-}" = install ] && [ "$TLS_INSTALL_POPULATES" = true ]; then TLS_TOOLS_READY=true; fi
}

@test "TLS headless missing tools never installs packages or host trust" {
  OCTOJOOM_NON_INTERACTIVE=true
  run joomlaTLSPrerequisites
  assert_status 2
  assert_output_contains 'Local HTTPS requires mkcert and OpenSSL'
  assert_output_contains 'mkcert -install interactively'
  refute_file_exists "$SANDBOX/package-commands"
  refute_file_exists "$SANDBOX/trust-commands"
}

@test "TLS available tools and trusted CA do not invoke any installer" {
  TLS_TOOLS_READY=true
  joomlaTLSPrerequisites
  assert_equal "$VDM_TLS_CAROOT" "$SANDBOX/local-ca"
  refute_file_exists "$SANDBOX/package-commands"
  refute_file_exists "$SANDBOX/trust-commands"
}

@test "TLS interactive Debian setup installs certificates and NSS through sudo" {
  run joomlaTLSPrerequisites
  assert_success
  assert_file_contains "$SANDBOX/package-commands" 'sudo apt-get update'
  assert_file_contains "$SANDBOX/package-commands" 'sudo apt-get install -y mkcert openssl libnss3-tools ca-certificates'
  refute_file_exists "$SANDBOX/trust-commands"
}

@test "TLS interactive Fedora setup uses dnf and NSS tooling" {
  TLS_MANAGER=dnf
  run joomlaTLSPrerequisites
  assert_success
  assert_file_contains "$SANDBOX/package-commands" 'sudo dnf install -y mkcert openssl nss-tools ca-certificates'
  refute_file_contains "$SANDBOX/package-commands" apt-get
}

@test "TLS interactive macOS setup uses Homebrew without sudo" {
  OS_NUMBER=2 TLS_MANAGER=brew
  run joomlaTLSPrerequisites
  assert_success
  assert_file_contains "$SANDBOX/package-commands" 'brew install mkcert nss openssl@3'
  refute_file_contains "$SANDBOX/package-commands" sudo
}

@test "TLS interactive Windows setup uses Chocolatey certificate packages" {
  OS_NUMBER=3 TLS_MANAGER=choco
  run joomlaTLSPrerequisites
  assert_success
  assert_file_contains "$SANDBOX/package-commands" 'choco install mkcert openssl.light --yes --no-progress'
  refute_file_contains "$SANDBOX/package-commands" sudo
}

@test "TLS unavailable package manager gives an actionable prerequisite message" {
  TLS_MANAGER=none
  run joomlaTLSPrerequisites
  assert_status 2
  assert_output_contains 'no supported package manager was found'
  assert_output_contains 'then choose Local trusted HTTPS again'
  refute_file_exists "$SANDBOX/package-commands"
  refute_file_exists "$SANDBOX/trust-commands"
}

@test "TLS package installation failure stops before CA trust changes" {
  TLS_INSTALL_STATUS=19
  run joomlaTLSPrerequisites
  assert_failure
  assert_output_contains 'installation failed (exit 19)'
  assert_output_contains 'sudo apt-get install -y mkcert openssl libnss3-tools'
  refute_file_contains "$SANDBOX/package-commands" 'apt-get install'
  refute_file_exists "$SANDBOX/trust-commands"
}

@test "TLS installer success is not enough when required tools remain unavailable" {
  TLS_INSTALL_POPULATES=false
  run joomlaTLSPrerequisites
  assert_status 2
  assert_output_contains 'mkcert or OpenSSL is still unavailable'
  assert_output_contains 'Reopen the terminal'
  refute_file_exists "$SANDBOX/trust-commands"
}

@test "TLS package preparation retains the separate CA trust confirmation" {
  TLS_TRUST_READY=false
  answers yes
  run joomlaTLSPrerequisites
  assert_success
  assert_answers_used
  assert_file_contains "$SANDBOX/trust-commands" install
  assert_file_contains "$STUB_DIR/dialogs.full" 'Install the mkcert local certificate authority'
}

@test "TLS declining CA trust does not install it or claim HTTPS is ready" {
  TLS_TOOLS_READY=true TLS_TRUST_READY=false
  answers no
  run joomlaTLSPrerequisites
  assert_failure
  assert_answers_used
  refute_file_exists "$SANDBOX/package-commands"
  refute_file_exists "$SANDBOX/trust-commands"
}
