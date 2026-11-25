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
  VDM_PHP_INI_TARGET=/usr/local/etc/php/conf.d/zz-octojoom.ini
  joomlaRuntimeIniTarget() { printf '%s\n' '/usr/local/etc/php/conf.d/zz-octojoom.ini'; }
  joomlaSetupPHPChoices() { return 0; }
  # Setup creates the INI here; startup preparation has separate acceptance tests.
  joomlaPHPEnsureSiteIni() { return 0; }
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

# Expert setup answers before the optional PHP/entrypoint questions. Version
# 4.2 keeps auto-deployment outside these focused failure-path regressions.
expert_single_answers() {
  answers "${JOOMENGINE_SOURCE}" 4.2 abc ABC abc no \
    abc_db abc_user userpass rootpass no yes yes no 1001 1002 "$@"
}

expert_bulk_answers() {
  answers "${JOOMENGINE_SOURCE}" 4.2 site no bulk_db bulk_user bulkpass 1001 1002 "$@"
}

fail_php_publication() {
  mv() {
    [[ "${*: -1}" != */php.ini && "${*: -1}" != */.php-bulk.* ]] || return 1
    command mv "$@"
  }
}

###############################################################################
# joomla__TRuST__setup

@test "joomla setup: basic mode writes the compose file and the database values" {
  octojoom_config
  # version, key, env key, sub-domain, database name/user/pass/root,
  # create env file, auto deploy, enable
  answers 5.3 jcb JCB jcb no jcb_db jcb_user userpass rootpass yes no no
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
  refute_command '^docker compose .* (up|start|restart)'
}

@test "joomla setup: the compose file and the env file are private" {
  skip_on_windows "file modes are not real on Windows"
  octojoom_config
  answers 5.3 jcb JCB jcb no jcb_db jcb_user userpass rootpass yes no no
  run joomla__TRuST__setup
  assert_success
  assert_equal "$(file_mode "$(compose_yml jcb.vdm.dev)")" 600
  assert_equal "$(file_mode "$(shared_env)")" 600
}

@test "joomla setup: the auto deploy details are saved for the container" {
  octojoom_config
  answers 5.3 jcb JCB jcb no jcb_db jcb_user userpass rootpass yes \
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
  answers 4.2 jcb JCB jcb no yes jcb_db jcb_user userpass rootpass yes no
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
  answers 4.2 xyz ABC xyz no no
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "$(compose_yml xyz.vdm.dev)" 'container_name: joomlaxyz'
  assert_file_contains "$(compose_yml xyz.vdm.dev)" '- MARIADB_DATABASE=${VDM_ABC_DB}'
  assert_equal "$(grep -c '^VDM_ABC_DB=' "$(shared_env)")" 1
}

@test "joomla setup: answering yes starts only the newly generated site" {
  # Existing-site enable does PHP discovery. Setup has just written this INI.
  joomlaPHPEnsureSiteIni() { return 41; }
  hasDirectories() { return 41; }
  octojoom_config
  answers 4.2 jcb JCB jcb no jcb_db jcb_user userpass rootpass yes yes
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
  answers "${JOOMENGINE_SOURCE}" 5.3 abc ABC abc no \
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
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/abc/php.ini:/usr/local/etc/php/conf.d/zz-octojoom.ini'
  assert_file_contains "${yml}" '${VDM_PROJECT_PATH}/abc/entrypoint.sh:/entrypoint.sh'
  assert_file_contains "$(shared_env)" 'VDM_ABC_PUID="#1001"'
  assert_file_contains "$(shared_env)" 'VDM_ABC_CLI_COMMANDS="cache:clean"'
  assert_file_contains "${VDM_PROJECT_PATH}/abc/php.ini" 'memory_limit = 1G'
  assert_file_contains "${VDM_PROJECT_PATH}/abc/entrypoint.sh" 'custom entrypoint'
}

@test "joomla setup: PHP publication failure stops before Compose publication or launch" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  fail_php_publication
  expert_single_answers yes 300 2000 5000 E_ALL 128M 64M 1G no
  run joomla__TRuST__setup
  assert_status 2
  assert_answers_used
  refute_file_exists "$(compose_yml abc.vdm.dev)"
  refute_command '^docker compose .* (up|start|restart)'
  refute_dialog 'Setup of this container is complete'
}

@test "joomla setup: entrypoint download failure preserves its status and prevents publication" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  fail_command curl 22
  expert_single_answers no yes
  run joomla__TRuST__setup
  assert_status 22
  assert_answers_used
  refute_file_exists "$(compose_yml abc.vdm.dev)"
  refute_command '^docker compose .* (up|start|restart)'
  refute_dialog 'Setup of this container is complete'
}

@test "joomla setup: explicitly declining both customizations still completes" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  expert_single_answers no no no
  run joomla__TRuST__setup
  assert_success
  assert_answers_used
  assert_file_exists "$(compose_yml abc.vdm.dev)"
  assert_file_contains "${VDM_PROJECT_PATH}/abc/php.ini" 'max_execution_time = 124'
  refute_file_exists "${VDM_PROJECT_PATH}/abc/entrypoint.sh"
}

###############################################################################
# joomla__TRuST__bulk

@test "joomla bulk: creates the asked number of containers" {
  octojoom_config
  # version, sub-domain, database name/user/pass, mailcatcher, auto deploy,
  # create env file, number of containers, enable
  answers 5.3 site no bulk_db bulk_user bulkpass no no yes 2 no
  run joomla__TRuST__bulk
  assert_success
  assert_answers_used
  assert_file_contains "$(compose_yml site1.vdm.dev)" 'image: joomla:5.3'
  assert_file_contains "$(compose_yml site2.vdm.dev)" 'Host(`site2.vdm.dev`)'
  refute_file_exists "$(compose_yml site3.vdm.dev)"
  assert_file_contains "$(shared_env)" '_DB="bulk_db1"'
  assert_file_contains "$(shared_env)" '_DB="bulk_db2"'
  local compose
  for compose in "$(compose_yml site1.vdm.dev)" "$(compose_yml site2.vdm.dev)"; do
    getJoomlaComposeIdentity "$compose"
    assert_file_contains "$compose" '${VDM_PROJECT_PATH}/'"${VDM_SRC_KEY}"'/joomla:/var/www/html'
    assert_file_contains "$compose" '${VDM_PROJECT_PATH}/'"${VDM_SRC_KEY}"'/db:/var/lib/mysql'
  done
  refute_command '^docker compose .* (up|start|restart)'
}

@test "joomla bulk: answering yes to enable starts every container" {
  octojoom_config
  answers 4.2 site no bulk_db bulk_user bulkpass no yes 2 yes
  run joomla__TRuST__bulk
  assert_success
  [ -e "${VDM_REPO_PATH}/joomla/enabled/site1.vdm.dev" ]
  [ -e "${VDM_REPO_PATH}/joomla/enabled/site2.vdm.dev" ]
  assert_command '^docker compose .*enabled/site1.vdm.dev/docker-compose.yml up -d'
  assert_command '^docker compose .*enabled/site2.vdm.dev/docker-compose.yml up -d'
}

@test "joomla bulk: a number of containers that is not between 2 and 99 is asked again" {
  octojoom_config
  answers 4.2 site no bulk_db bulk_user bulkpass no yes ten 1 100 3 no
  run joomla__TRuST__bulk
  assert_success
  assert_file_exists "$(compose_yml site3.vdm.dev)"
  refute_file_exists "$(compose_yml site4.vdm.dev)"
}

@test "joomla bulk: PHP publication failure prevents every Compose publication and launch" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  fail_php_publication
  expert_bulk_answers yes 300 2000 5000 E_ALL 128M 64M 1G no
  run joomla__TRuST__bulk
  assert_status 2
  assert_answers_used
  refute_file_exists "${VDM_REPO_PATH}/joomla/available"
  refute_command '^docker compose .* (up|start|restart)'
}

@test "joomla bulk: entrypoint failure aborts before container-count and enable questions" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  fail_command curl 22
  expert_bulk_answers no yes
  run joomla__TRuST__bulk
  assert_status 22
  assert_answers_used
  refute_file_exists "${VDM_REPO_PATH}/joomla/available"
  refute_command '^docker compose .* (up|start|restart)'
  refute_dialog 'Enter the number of containers'
}

@test "joomla bulk: declining PHP and entrypoint customization still creates every container" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  expert_bulk_answers no no yes yes no yes 2 no
  run joomla__TRuST__bulk
  assert_success
  assert_answers_used
  assert_file_exists "$(compose_yml site1.vdm.dev)"
  assert_file_exists "$(compose_yml site2.vdm.dev)"
  refute_file_exists "${VDM_PROJECT_PATH}/bulk/php.ini"
  refute_file_exists "${VDM_PROJECT_PATH}/bulk/entrypoint.sh"
}

@test "joomla bulk: cancelling persistence leaves deployment and project data untouched" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  expert_bulk_answers no no '<esc>'
  run joomla__TRuST__bulk
  assert_status 255
  assert_answers_used
  refute_file_exists "${VDM_REPO_PATH}/joomla/available"
  refute_file_exists "${VDM_REPO_PATH}/joomla/.env"
  refute_command '^docker compose .* (up|start|restart)'
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

@test "setPHPSettings: declining customization writes the global defaults" {
  octojoom_config 'VDM_max_execution_time=210' 'VDM_memory_limit="640M"'
  VDM_PHP_PROJECT_PATH=abc
  answers no
  run setPHPSettings
  assert_success
  assert_file_contains "${VDM_PROJECT_PATH}/abc/php.ini" 'max_execution_time = 210'
  assert_file_contains "${VDM_PROJECT_PATH}/abc/php.ini" 'memory_limit = 640M'
  assert_answers_used
}

@test "optional customizations: cancellation at the initial prompts is a hard error" {
  VDM_PHP_PROJECT_PATH=abc
  VDM_ENTRY_PROJECT_PATH=abc
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  answers '<esc>' '<esc>'
  run setPHPSettings
  assert_status 255
  run setDockerEntrypoint
  assert_status 255
  assert_answers_used
  refute_file_exists "${VDM_PROJECT_PATH}/abc/php.ini"
  refute_command 'curl '
}

@test "setPHPSettings: cancellation at the additional edit prompt leaves no published PHP file" {
  octojoom_config 'VDM_EXPERT_MODE=true'
  VDM_PHP_PROJECT_PATH=abc
  answers yes 300 2000 5000 E_ALL 128M 64M 1G '<esc>'
  run setPHPSettings
  assert_status 255
  assert_answers_used
  refute_command '^sudo chown'
  refute_command '^sudo chmod'
}

@test "setPHPSettings: custom values belong to this site and do not replace global defaults" {
  octojoom_config 'VDM_memory_limit="640M"'
  cp "${VDM_SRC_PATH}/.env" "$SANDBOX/global.before"
  VDM_PHP_PROJECT_PATH=abc
  answers yes 300 2000 5000 E_ALL 128M 64M 1G
  run setPHPSettings
  assert_success
  local ini="${VDM_PROJECT_PATH}/abc/php.ini"
  assert_file_contains "${ini}" 'max_execution_time = 300'
  assert_file_contains "${ini}" 'memory_limit = 1G'
  cmp "$SANDBOX/global.before" "${VDM_SRC_PATH}/.env"
  if [ "$OS_NUMBER" -ne 3 ]; then assert_equal "$(file_mode "$ini")" 644; fi
  refute_command '^sudo (chown|chmod)'
}

@test "setPHPSettings: a cancelled answer does not partially update global settings" {
  octojoom_config
  cp "${VDM_SRC_PATH}/.env" "$SANDBOX/global.before"
  VDM_PHP_PROJECT_PATH=abc
  answers yes 300 '<esc>'
  run setPHPSettings
  assert_status 255
  refute_file_exists "${VDM_PROJECT_PATH}/abc/php.ini"
  cmp "$SANDBOX/global.before" "${VDM_SRC_PATH}/.env"
}

@test "setPHPSettings: publication failure preserves the previous override" {
  octojoom_config
  VDM_PHP_PROJECT_PATH=abc
  mkdir -p "${VDM_PROJECT_PATH}/abc"
  printf 'date.timezone = UTC\n' > "${VDM_PROJECT_PATH}/abc/php.ini"
  mv() { [[ "${*: -1}" != */php.ini ]] || return 7; command mv "$@"; }
  answers yes 300 2000 5000 E_ALL 128M 64M 1G
  run setPHPSettings
  assert_status 7
  assert_equal "$(cat "${VDM_PROJECT_PATH}/abc/php.ini")" 'date.timezone = UTC'
}

###############################################################################
# setDockerEntrypoint

@test "setDockerEntrypoint: declined, nothing is downloaded" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  answers no
  run setDockerEntrypoint
  assert_status 1
  refute_command 'curl '
  refute_file_exists "${VDM_PROJECT_PATH}/abc/entrypoint.sh"
}

@test "setDockerEntrypoint: selected command status one is a hard error, distinct from No" {
  VDM_ENTRY_REPO='https://example.org/docker-entrypoint.sh'
  VDM_ENTRY_PROJECT_PATH=abc
  fail_command curl 1
  answers yes
  run setDockerEntrypoint
  assert_status 2
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
  assert_status 22
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
  assert_status 22
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
  assert_status 7
  assert_equal "$(cat "${VDM_PROJECT_PATH}/abc/entrypoint.sh")" 'original entrypoint'
}

@test "joomla setup: an operator-owned Joomla environment stays byte-for-byte intact" {
  octojoom_config
  local shared site
  shared="$(shared_env)"
  site="${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev"
  mkdir -p "${shared%/*}"
  cat > "$shared" <<'ENV'
# Local Compose project
COMPOSE_PROJECT_NAME=operators
CUSTOM_LITERAL='first line
VDM_ALPHA_DB_PASS="should never become a password"
VDM_PROJECT_PATH="/not-a-project"
'
export VDM_ALPHA_DB='operator_db'
UNRELATED=${LOCAL_TAG:-default}
VDM_BRAVO_DB_PASS="sibling secret"
this is managed by another tool
ENV
  # The absent trailing newline is deliberate.
  printf '%s' 'CUSTOM_LAST=unchanged' >> "$shared"
  cp "$shared" "$SANDBOX/original.env"
  answers 4.2 alpha ALPHA alpha no chosen_user chosen_pass chosen_root no
  run joomla__TRuST__setup
  assert_success
  assert_answers_used
  cmp "$SANDBOX/original.env" "$shared"
  assert_file_contains "$site/.env" 'VDM_ALPHA_DB="operator_db"'
  assert_file_contains "$site/.env" 'VDM_ALPHA_DB_USER="chosen_user"'
  assert_file_contains "$site/.env" 'VDM_ALPHA_DB_PASS="chosen_pass"'
  assert_file_contains "$site/.env" "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\""
  assert_file_contains "$site/docker-compose.yml" 'container_name: joomlaalpha'
  ! grep -Eq 'CUSTOM_|COMPOSE_PROJECT_NAME|VDM_BRAVO_' "$site/.env"
}

@test "setup defaults: only requested keys are read and quoted foreign records cannot supply values" {
  local env_file="$SANDBOX/custom.env"
  local VDM_OK='' VDM_OTHER=untouched VDM_FAKE=untouched VDM_SECURE=true
  cat > "$env_file" <<'ENV'
CUSTOM: "line one with an escaped \" quote
VDM_FAKE=forged
"
VDM_OTHER=no
export VDM_OK=earlier
VDM_OK='literal $(pwd)'
VDM_SECURE=bogus
ENV
  readSetupEnvValues "$env_file" VDM_OK VDM_FAKE VDM_SECURE
  assert_equal "$VDM_OK" 'literal $(pwd)'
  assert_equal "$VDM_OTHER" untouched
  assert_equal "$VDM_FAKE" untouched
  assert_equal "$VDM_SECURE" true
}
