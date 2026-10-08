#!/usr/bin/env bats
#
# Domains and host names: the domain list (${VDM_SRC_PATH}/.domains), the single
# and multiple domain setups, the sub-domain, key and environment key questions,
# the secure (Letsencrypt, Cloudflare) switches and the hosts file updates.
#
# The hosts file is never written: the sudo stand-in refuses paths outside the
# sandbox and keeps what would have been appended in ${STUB_DIR}/sudo-tee.log.
# The host name used (octojoomtest.invalid) is in no real hosts file.

# SC2030/SC2031: each test runs in its own subshell, so changing a global in one is intended.
# SC2034: the VDM_* and OS_NUMBER globals are read by the loaded script functions.
# shellcheck disable=SC2030,SC2031,SC2034

load ../helpers/common

setup() {
  octojoom_setup
}

DOMAINS() { echo "${VDM_SRC_PATH}/.domains"; }
ENV_FILE() { echo "${VDM_SRC_PATH}/.env"; }

# write the domain list, one domain per argument
domains_file() {
  printf '%s\n' "$@" >"$(DOMAINS)"
}

# no dialog was shown
refute_dialogs() {
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

###############################################################################
# the domain list

@test "getListDomains: lists the saved domains with the separator" {
  domains_file a.dev '' b.dev
  run getListDomains ", "
  assert_success
  assert_equal "${output}" ", a.dev, b.dev"
}

@test "saveMultiDomain: creates the list and adds a domain only once" {
  rm -rf "${VDM_SRC_PATH}"
  run saveMultiDomain vdm.dev
  assert_success
  run saveMultiDomain octo.dev
  run saveMultiDomain vdm.dev
  assert_success
  assert_equal "$(cat "$(DOMAINS)")" $'vdm.dev\nocto.dev'
}

@test "saveMultiDomain: an empty domain is not saved" {
  run saveMultiDomain '  '
  assert_success
  refute_file_exists "$(DOMAINS)"
}

@test "deleteMultiDomains: removes the selected domains and keeps the others" {
  domains_file a.dev b.dev c.dev
  answers '"a.dev" "c.dev"'
  run deleteMultiDomains
  assert_success
  assert_equal "$(cat "$(DOMAINS)")" "b.dev"
}

@test "deleteMultiDomains: nothing selected leaves the list unchanged" {
  domains_file a.dev b.dev
  answers ''
  run deleteMultiDomains
  assert_success
  assert_equal "$(cat "$(DOMAINS)")" $'a.dev\nb.dev'
}

###############################################################################
# getDomain, setDomain, getMultiDomain

@test "getDomain: keeps a valid domain that is already set" {
  VDM_DOMAIN=vdm.dev
  getDomain
  assert_equal "${VDM_DOMAIN}" "vdm.dev"
  refute_dialogs
}

@test "getDomain: asks again until the domain has a dot" {
  answers '' nodot octo.dev
  getDomain
  assert_equal "${VDM_DOMAIN}" "octo.dev"
}

@test "setDomain: single domain setup asks for a missing domain and saves it" {
  octojoom_config
  unset VDM_DOMAIN
  answers asked.dev
  setDomain
  assert_answers_used
  assert_equal "${VDM_DOMAIN}" "asked.dev"
  assert_file_contains "$(ENV_FILE)" 'VDM_DOMAIN="asked.dev"'
  refute_file_contains "$(ENV_FILE)" 'VDM_DOMAIN="vdm.dev"'
}

@test "setDomain: multiple domain setup uses the selected domain" {
  octojoom_config 'VDM_MULTI_DOMAIN=true'
  domains_file octo.dev
  answers octo.dev
  setDomain
  assert_answers_used
  assert_equal "${VDM_DOMAIN}" "octo.dev"
}

@test "getMultiDomain: adds the main domain to the list and sets the selection" {
  VDM_DOMAIN=vdm.dev
  domains_file octo.dev
  answers octo.dev
  getMultiDomain
  assert_equal "${VDM_DOMAIN}" "octo.dev"
  assert_equal "$(cat "$(DOMAINS)")" $'octo.dev\nvdm.dev'
}

@test "getMultiDomain: without a selection asks for a new domain and saves it" {
  VDM_DOMAIN=vdm.dev
  answers '' new.dev
  getMultiDomain
  assert_equal "${VDM_DOMAIN}" "new.dev"
  assert_equal "$(cat "$(DOMAINS)")" $'vdm.dev\nnew.dev'
}

###############################################################################
# sub-domain and keys

@test "setSubDomain: refuses empty, non-letter and used sub-domains" {
  VDM_CONTAINER_TYPE=joomla
  VDM_DOMAIN=vdm.dev
  mkdir -p "${VDM_REPO_PATH}/joomla/available/taken.vdm.dev"
  answers '' 'my site' taken free
  setSubDomain '' joomla
  assert_equal "${VDM_SUBDOMAIN}" "free"
}

@test "setSubDomain: keeps a valid sub-domain that is already set" {
  VDM_CONTAINER_TYPE=joomla
  VDM_DOMAIN=vdm.dev
  VDM_SUBDOMAIN=site
  setSubDomain site joomla
  assert_equal "${VDM_SUBDOMAIN}" "site"
  refute_dialogs
}

@test "setUniqueKey: refuses an invalid key and one whose project folder exists" {
  mkdir -p "${VDM_PROJECT_PATH}/used"
  answers '' key1 used fresh
  setUniqueKey
  assert_equal "${VDM_KEY}" "fresh"
}

@test "setEnvironmentKey: refuses an invalid key and keeps asking" {
  answers '' K 'MY KEY' GOOD
  setEnvironmentKey
  assert_equal "${VDM_ENV_KEY}" "GOOD"
}

###############################################################################
# secure switches

@test "setSecureState: asks and saves the answer in the config" {
  : >"$(ENV_FILE)"
  answers yes
  setSecureState
  assert_equal "${VDM_SECURE}" "true"
  assert_file_contains "$(ENV_FILE)" "VDM_SECURE=true"
}

@test "setSecureState: with --force takes no without asking" {
  : >"$(ENV_FILE)"
  VDM_FORCE=true
  setSecureState
  assert_equal "${VDM_SECURE}" "false"
  assert_file_contains "$(ENV_FILE)" "VDM_SECURE=false"
  refute_dialogs
}

@test "setSecureCloudflareState: sets the answer" {
  answers yes
  setSecureCloudflareState traefik
  assert_equal "${VDM_SECURE_CLOUDFLARE}" "true"
  answers no
  setSecureCloudflareState joomla
  assert_equal "${VDM_SECURE_CLOUDFLARE}" "false"
}

###############################################################################
# hosts file

@test "setUpdateHostFile: asks and saves the answer in the config" {
  : >"$(ENV_FILE)"
  answers yes
  setUpdateHostFile
  assert_equal "${VDM_UPDATE_HOST}" "true"
  assert_file_contains "$(ENV_FILE)" "VDM_UPDATE_HOST=true"
}

@test "updateHostFile: Linux adds the host to /etc/hosts through sudo" {
  octojoom_config 'VDM_UPDATE_HOST=true'
  OS_NUMBER=1
  answers yes
  run updateHostFile octojoomtest invalid
  assert_success
  assert_answers_used
  assert_command '^sudo-skipped tee -a /etc/hosts$'
  assert_file_contains "${STUB_DIR}/sudo-tee.log" "127.0.0.1       octojoomtest.invalid"
}

@test "updateHostFile: declining sudo writes nothing" {
  octojoom_config 'VDM_UPDATE_HOST=true'
  OS_NUMBER=1
  answers no
  run updateHostFile octojoomtest invalid
  assert_success
  refute_command '^sudo'
}

@test "updateHostFile: does nothing when host updates are off" {
  octojoom_config
  OS_NUMBER=1
  run updateHostFile octojoomtest invalid
  assert_success
  refute_dialogs
  refute_command '^sudo'
}

@test "updateHostFile: Windows adds the host to the Windows hosts file" {
  octojoom_config 'VDM_UPDATE_HOST=true'
  OS_NUMBER=3
  VDM_SUBDOMAIN=octojoomtest
  VDM_DOMAIN=invalid
  answers yes
  run updateHostFile
  assert_success
  assert_command '^sudo-skipped tee -a /c/Windows/System32/drivers/etc/hosts$'
  assert_file_contains "${STUB_DIR}/sudo-tee.log" "octojoomtest.invalid"
}

@test "updateHostFile: fails on an unknown system" {
  octojoom_config 'VDM_UPDATE_HOST=true'
  OS_NUMBER=0
  run updateHostFile octojoomtest invalid
  assert_failure
  refute_command '^sudo'
}
