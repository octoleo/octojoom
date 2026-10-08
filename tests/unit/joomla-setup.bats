#!/usr/bin/env bats
#
# Setting up Joomla containers: the single setup (joomla__TRuST__setup) in
# basic and expert mode, the bulk setup (joomla__TRuST__bulk), the website
# auto deploy questions (setJoomlaWebsiteDetails), the CLI command check
# (joomlaValidateCliCommand), the PHP overrides (setPHPSettings) and the
# custom entrypoint download (setDockerEntrypoint).
#
# SC2034: the VDM_* globals are read by the loaded script functions.
# SC2016: the expected compose lines hold a literal ${...}.
# shellcheck disable=SC2016,SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  VDM_CONTAINER_TYPE='joomla'
}

# the joomengine image source offered in expert mode (a radiolist tag)
JOOMENGINE_SOURCE='octoleo/joomengine|https://hub.docker.com/r/octoleo/joomengine/tags;https://raw.githubusercontent.com/octoleo/joomengine/refs/heads/master/src/docker/docker-entrypoint.sh'

# the docker-compose.yml of an available container: compose_yml <container>
compose_yml() {
  echo "${VDM_REPO_PATH}/joomla/available/$1/docker-compose.yml"
}

# the shared env file of the Joomla containers
shared_env() {
  echo "${VDM_REPO_PATH}/joomla/.env"
}

###############################################################################
# joomla__TRuST__setup

@test "joomla setup: basic mode writes the compose file and the database values" {
  octojoom_config
  # version, key, env key, sub-domain, database name/user/pass/root,
  # create env file, auto deploy, enable
  answers 5.3 jcb JCB jcb jcb_db jcb_user userpass rootpass yes no no
  run joomla__TRuST__setup
  assert_success
  assert_answers_used
  local yml
  yml="$(compose_yml jcb.vdm.dev)"
  assert_file_contains "${yml}" 'image: joomla:5.3'
  assert_file_contains "${yml}" 'container_name: joomlajcb'
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/jcb/joomla:/var/www/html'
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/jcb/db:/var/lib/mysql'
  assert_file_contains "$(shared_env)" 'VDM_JCB_DB="jcb_db"'
  assert_file_contains "$(shared_env)" 'VDM_JCB_DB_PASS="userpass"'
  assert_file_contains "$(shared_env)" 'VDM_JCB_DB_ROOT="rootpass"'
  refute_file_exists "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
  refute_command '^docker compose'
}

@test "joomla setup: the compose file and the env file are private" {
  skip_on_windows "file modes are not real on Windows"
  octojoom_config
  answers 5.3 jcb JCB jcb jcb_db jcb_user userpass rootpass yes no no
  run joomla__TRuST__setup
  assert_success
  assert_equal "$(file_mode "$(compose_yml jcb.vdm.dev)")" 600
  assert_equal "$(file_mode "$(shared_env)")" 600
}

@test "joomla setup: the auto deploy details are saved for the container" {
  octojoom_config
  answers 5.3 jcb JCB jcb jcb_db jcb_user userpass rootpass yes \
    yes 'Octo Site' admin 'Octo Admin' admin@vdm.dev 'a-strong-password' \
    'https://example.org/pkg.zip' '' \
    no
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "$(shared_env)" 'VDM_JCB_JOOMLA_SITE_NAME="Octo Site"'
  assert_file_contains "$(shared_env)" 'VDM_JCB_JOOMLA_ADMIN_EMAIL="admin@vdm.dev"'
  assert_file_contains "$(shared_env)" 'VDM_JCB_EXTENSIONS_URLS="https://example.org/pkg.zip"'
  assert_file_contains "$(compose_yml jcb.vdm.dev)" '- JOOMLA_SITE_NAME=${VDM_JCB_JOOMLA_SITE_NAME}'
}

@test "joomla setup: Letsencrypt behind Cloudflare adds the secure labels" {
  octojoom_config 'VDM_SECURE=true'
  # the Cloudflare question comes after the sub-domain
  answers 4.2 jcb JCB jcb yes jcb_db jcb_user userpass rootpass yes no
  run joomla__TRuST__setup
  assert_success
  local yml
  yml="$(compose_yml jcb.vdm.dev)"
  assert_file_contains "${yml}" 'traefik.http.routers.joomlajcb.entrypoints=websecure'
  assert_file_contains "${yml}" 'traefik.http.routers.joomlajcb.tls.certresolver=cfresolver'
}

@test "joomla setup: an existing env key reuses its database values" {
  octojoom_config
  make_joomla_container abc ABC abc
  # key, env key, sub-domain: no database questions, then no enable
  answers 4.2 xyz ABC xyz no
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "$(compose_yml xyz.vdm.dev)" 'container_name: joomlaxyz'
  assert_file_contains "$(compose_yml xyz.vdm.dev)" '- MARIADB_DATABASE=${VDM_ABC_DB}'
  assert_equal "$(grep -c '^VDM_ABC_DB=' "$(shared_env)")" 1
}

@test "joomla setup: answering yes to enable starts the container" {
  octojoom_config
  answers 4.2 jcb JCB jcb jcb_db jcb_user userpass rootpass yes yes
  run joomla__TRuST__setup
  assert_success
  [ -e "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev" ]
  assert_command '^docker compose .*enabled/jcb.vdm.dev/docker-compose.yml up -d'
}

@test "joomla setup: expert mode with every option builds the full compose file" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  printf '#!/bin/bash\necho "custom entrypoint"\n' >"${STUB_DIR}/curl-body"
  # image source, version, key, env key, sub-domain, database values,
  # persistence (website no, database yes), create env file, mailcatcher,
  # user and group IDs, auto deploy with one extension and one CLI command,
  # PHP overrides (no editor), entrypoint, enable
  answers "${JOOMENGINE_SOURCE}" 5.3 abc ABC abc \
    abc_db abc_user userpass rootpass \
    no yes \
    yes \
    yes \
    1001 1002 \
    yes 'Octo Site' admin 'Octo Admin' admin@vdm.dev 'a-strong-password' \
    'https://example.org/pkg.zip' '' \
    'cache:clean' '' \
    yes 300 2000 5000 'E_ALL' 512M 512M 1G no \
    yes \
    no
  run joomla__TRuST__setup
  assert_success
  assert_answers_used
  local yml
  yml="$(compose_yml abc.vdm.dev)"
  assert_file_contains "${yml}" 'image: octoleo/joomengine:5.3'
  assert_file_contains "${yml}" '- abc_web:/var/www/html'
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/abc/db:/var/lib/mysql'
  assert_file_contains "${yml}" 'container_name: mailcatcherabc'
  assert_file_contains "${yml}" '- APACHE_RUN_USER=${VDM_ABC_PUID}'
  assert_file_contains "${yml}" '- JOOMLA_CLI_COMMANDS=${VDM_ABC_CLI_COMMANDS}'
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/abc/php.ini:/var/www/html/php.ini'
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/abc/entrypoint.sh:/entrypoint.sh'
  assert_file_contains "$(shared_env)" 'VDM_ABC_PUID="#1001"'
  assert_file_contains "$(shared_env)" 'VDM_ABC_CLI_COMMANDS="cache:clean"'
  assert_file_contains "${VDM_PROJECT_PATH}/abc/php.ini" 'memory_limit = 1G'
  assert_file_contains "${VDM_PROJECT_PATH}/abc/entrypoint.sh" 'custom entrypoint'
}

###############################################################################
# joomla__TRuST__bulk

@test "joomla bulk: creates the asked number of containers" {
  octojoom_config
  # version, sub-domain, database name/user/pass, mailcatcher, auto deploy,
  # create env file, number of containers, enable
  answers 5.3 site bulk_db bulk_user bulkpass no no yes 2 no
  run joomla__TRuST__bulk
  assert_success
  assert_answers_used
  assert_file_contains "$(compose_yml site1.vdm.dev)" 'image: joomla:5.3'
  assert_file_contains "$(compose_yml site2.vdm.dev)" 'Host(`site2.vdm.dev`)'
  refute_file_exists "$(compose_yml site3.vdm.dev)"
  assert_file_contains "$(shared_env)" '_DB="bulk_db1"'
  assert_file_contains "$(shared_env)" '_DB="bulk_db2"'
  refute_command '^docker compose'
}

@test "joomla bulk: answering yes to enable starts every container" {
  octojoom_config
  answers 4.2 site bulk_db bulk_user bulkpass no yes 2 yes
  run joomla__TRuST__bulk
  assert_success
  [ -e "${VDM_REPO_PATH}/joomla/enabled/site1.vdm.dev" ]
  [ -e "${VDM_REPO_PATH}/joomla/enabled/site2.vdm.dev" ]
  assert_command '^docker compose .*enabled/site1.vdm.dev/docker-compose.yml up -d'
  assert_command '^docker compose .*enabled/site2.vdm.dev/docker-compose.yml up -d'
}

@test "joomla bulk: a number of containers that is not between 2 and 99 is asked again" {
  octojoom_config
  answers 4.2 site bulk_db bulk_user bulkpass no yes ten 1 100 3 no
  run joomla__TRuST__bulk
  assert_success
  assert_file_exists "$(compose_yml site3.vdm.dev)"
  refute_file_exists "$(compose_yml site4.vdm.dev)"
}

###############################################################################
# setJoomlaWebsiteDetails

@test "setJoomlaWebsiteDetails: declined, nothing is set" {
  VDM_JV=5.3
  VDM_J_REPO=joomla
  answers no
  setJoomlaWebsiteDetails
  [ -z "${VDM_J_SITE_NAME:-}" ]
  [ -z "${VDM_J_EMAIL:-}" ]
}

@test "setJoomlaWebsiteDetails: the official image sets the website details" {
  VDM_JV=5.3
  VDM_J_REPO=joomla
  answers yes 'Octo Site' admin 'Octo Admin' admin@vdm.dev 'a-strong-password' ''
  setJoomlaWebsiteDetails
  assert_equal "${VDM_J_SITE_NAME}" 'Octo Site'
  assert_equal "${VDM_J_USERNAME}" 'admin'
  assert_equal "${VDM_J_EMAIL}" 'admin@vdm.dev'
  assert_equal "${VDM_J_PASSWORD}" 'a-strong-password'
  [ -z "${VDM_J_CLI_COMMANDS:-}" ]
}

@test "setJoomlaWebsiteDetails: the joomengine image also takes CLI commands" {
  VDM_JV=5.3
  VDM_J_REPO=octoleo/joomengine
  answers yes 'Octo Site' admin 'Octo Admin' admin@vdm.dev 'a-strong-password' '' \
    'cache:clean' 'extension:discover' ''
  setJoomlaWebsiteDetails
  assert_equal "${VDM_J_CLI_COMMANDS}" 'cache:clean;extension:discover'
}

###############################################################################
# joomlaValidateCliCommand

@test "joomlaValidateCliCommand: accepts ordinary Joomla CLI commands" {
  run joomlaValidateCliCommand 'cache:clean'
  assert_success
  run joomlaValidateCliCommand 'extension:install --url=https://example.org/pkg.zip'
  assert_success
}

@test "joomlaValidateCliCommand: refuses empty, too short and too long commands" {
  run joomlaValidateCliCommand ''
  assert_failure
  run joomlaValidateCliCommand 'abcd'
  assert_failure
  run joomlaValidateCliCommand "$(printf '%4097s' '' | tr ' ' a)"
  assert_failure
}

@test "joomlaValidateCliCommand: refuses several lines and shell substitution" {
  run joomlaValidateCliCommand $'cache:clean\nsite:down'
  assert_failure
  run joomlaValidateCliCommand 'site:down `id`'
  assert_failure
  run joomlaValidateCliCommand 'site:down $(id)'
  assert_failure
  run joomlaValidateCliCommand 'cache:clean;site:down'
  assert_failure
}

@test "setJoomlaWebsiteDetails: input cancellation stops the setup questions" {
  VDM_JV=5.3
  VDM_J_REPO=joomla
  answers yes '<esc>'
  run setJoomlaWebsiteDetails
  assert_status 255
  assert_answers_used
}

@test "setJoomlaExtensionUrls and setJoomlaCommands: empty input clears old optional values" {
  VDM_J_EXTENSIONS_URLS='https://example.org/old.zip'
  VDM_J_CLI_COMMANDS='site:down'
  answers '' ''
  setJoomlaExtensionUrls
  setJoomlaCommands
  [ -z "${VDM_J_EXTENSIONS_URLS:-}" ]
  [ -z "${VDM_J_CLI_COMMANDS:-}" ]
}

###############################################################################
# setPHPSettings

@test "setPHPSettings: declined, nothing is written" {
  octojoom_config
  VDM_PHP_PROJECT_PATH=abc
  answers no
  run setPHPSettings
  assert_failure
  refute_file_exists "${VDM_PROJECT_PATH}/abc/php.ini"
}

@test "setPHPSettings: writes php.ini and remembers the values" {
  octojoom_config
  VDM_PHP_PROJECT_PATH=abc
  answers yes 300 2000 5000 E_ALL 128M 64M 1G
  run setPHPSettings
  assert_success
  local ini="${VDM_PROJECT_PATH}/abc/php.ini"
  assert_file_contains "${ini}" 'max_execution_time = 300'
  assert_file_contains "${ini}" 'memory_limit = 1G'
  assert_file_contains "${VDM_SRC_PATH}/.env" 'VDM_memory_limit="1G"'
  assert_command "^sudo chmod 600 ${ini}$"
}

@test "setPHPSettings: failed config persistence stops before generating php.ini" {
  octojoom_config
  VDM_PHP_PROJECT_PATH=abc
  setUniqueEnvVariable() { return 12; }
  answers yes 300
  run setPHPSettings
  assert_status 12
  refute_file_exists "${VDM_PROJECT_PATH}/abc/php.ini"
}

@test "setPHPSettings: ownership failure is not reported as usable overrides" {
  octojoom_config
  VDM_PHP_PROJECT_PATH=abc
  hook_command sudo <<'EOF'
[ "$1" != chown ] || exit 7
exit 0
EOF
  answers yes 300 2000 5000 E_ALL 128M 64M 1G
  run setPHPSettings
  assert_status 7
  refute_command '^sudo chmod'
}

###############################################################################
# setDockerEntrypoint

@test "setDockerEntrypoint: declined, nothing is downloaded" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  answers no
  run setDockerEntrypoint
  assert_failure
  refute_command 'curl '
  refute_file_exists "${VDM_PROJECT_PATH}/abc/entrypoint.sh"
}

@test "setDockerEntrypoint: downloads the entrypoint and makes it executable" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  printf '#!/bin/bash\necho "custom entrypoint"\n' >"${STUB_DIR}/curl-body"
  answers yes
  run setDockerEntrypoint
  assert_success
  local file="${VDM_PROJECT_PATH}/abc/entrypoint.sh"
  assert_file_contains "${file}" 'custom entrypoint'
  assert_command "curl --fail -L https://example.org/docker-entrypoint.sh -o ${file}\.tmp\."
  assert_command "^sudo chmod 700 ${file}\.tmp\."
  [ -x "$file" ]
}

@test "setDockerEntrypoint: a failed download is not used" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  fail_command curl 22
  answers yes
  run setDockerEntrypoint
  assert_failure
  refute_command '^sudo chmod'
  refute_file_exists "${VDM_PROJECT_PATH}/abc/entrypoint.sh"
}

@test "setDockerEntrypoint: partial download failure preserves an existing script" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  mkdir -p "${VDM_PROJECT_PATH}/abc"
  printf '%s\n' 'original entrypoint' > "${VDM_PROJECT_PATH}/abc/entrypoint.sh"
  hook_command curl <<'EOF'
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then
    printf '%s' 'partial download' > "$2"
    exit 22
  fi
  shift
done
exit 22
EOF
  answers yes
  run setDockerEntrypoint
  assert_failure
  assert_equal "$(cat "${VDM_PROJECT_PATH}/abc/entrypoint.sh")" 'original entrypoint'
  [ -z "$(find "${VDM_PROJECT_PATH}/abc" -name 'entrypoint.sh.tmp.*' -print)" ]
}

@test "setDockerEntrypoint: failed executable permissions preserve an existing script" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  mkdir -p "${VDM_PROJECT_PATH}/abc"
  printf '%s\n' 'original entrypoint' > "${VDM_PROJECT_PATH}/abc/entrypoint.sh"
  hook_command sudo <<'EOF'
case "$1" in
  chmod) exit 7 ;;
  chown) exit 0 ;;
esac
exec "$@"
EOF
  answers yes
  run setDockerEntrypoint
  assert_failure
  assert_equal "$(cat "${VDM_PROJECT_PATH}/abc/entrypoint.sh")" 'original entrypoint'
}
