#!/usr/bin/env bats
# Each Bats case gets an independent sandbox and variable scope.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE=joomla
}

# Real command startup has the same prompt policy; a reached question here is
# a missing input regression rather than an answer supplied by a fake terminal.
headless_setup() {
  OCTOJOOM_NON_INTERACTIVE=true
  getInput() { printf 'Unexpected input question: %s\n' "$1" >&2; return 17; }
  getPassword() { printf 'Unexpected password question: %s\n' "$1" >&2; return 17; }
  getInputYesNo() {
    [ "$2" = 'Environment Variable File' ] || { printf 'Unexpected confirmation: %s\n' "$2" >&2; return 17; }
  }
  showNotice() { :; }
  VDM_KEY=alpha
  VDM_DOMAIN=example.test
}

@test "setup: missing required identity fails before first-run files are created" {
  OCTOJOOM_NON_INTERACTIVE=true
  VDM_KEY=''
  VDM_REPO_PATH="${SANDBOX}/missing/repo"
  VDM_PROJECT_PATH="${SANDBOX}/missing/projects"
  run joomlaSetupPreflight
  assert_status 17
  refute_file_exists "${SANDBOX}/missing"
  refute_command '^docker '
}

@test "setup: cancelling the optional fork leaves shared credentials and deployment untouched" {
  answers 5.3 alpha ALPHA alpha '<esc>'
  run joomla__TRuST__setup
  assert_status 255
  refute_file_exists "${VDM_REPO_PATH}/joomla/.env"
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev/docker-compose.yml"
  assert_answers_used
}

@test "setup: fully supplied manual setup generates private passwords without dialogs" {
  headless_setup
  run joomla__TRuST__setup
  assert_success
  local env_file="${VDM_REPO_PATH}/joomla/.env" saved
  assert_file_contains "$env_file" 'VDM_ALPHA_DB="vdm_io"'
  migrationReadEnvValue "$env_file" VDM_ALPHA_DB_PASS saved
  [ "${#saved}" -eq 20 ]
  migrationReadEnvValue "$env_file" VDM_ALPHA_DB_ROOT saved
  [ "${#saved}" -eq 40 ]
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml" 'image: joomla:latest'
  refute_file_exists "${VDM_REPO_PATH}/joomla/enabled/alpha.example.test"
  assert_command '^docker compose .* config --quiet$'
  refute_command '^whiptail '
}

@test "setup: failed validation preserves shared values and publishes no Compose" {
  make_joomla_container bravo BRAVO bravo
  cp "${VDM_REPO_PATH}/joomla/.env" "${SANDBOX}/before.env"
  headless_setup
  fail_command docker-compose-config 23
  run joomla__TRuST__setup
  assert_status 23
  cmp "${SANDBOX}/before.env" "${VDM_REPO_PATH}/joomla/.env"
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml"
  refute_command '^docker compose .* up '
}

@test "setup: explicit future defaults survive reload and one site's override does not replace them" {
  headless_setup
  VDM_J_REPO=custom/joomla
  VDM_JV=stable
  VDM_SAVE_DEFAULTS=true
  joomla__TRuST__setup
  assert_file_contains "${VDM_SRC_PATH}/.env" 'VDM_DEFAULT_JOOMLA_IMAGE_SOURCE="custom/joomla"'
  loadEnvFile "${VDM_SRC_PATH}/.env"
  unset VDM_J_REPO VDM_JV VDM_SAVE_DEFAULTS
  VDM_KEY=bravo
  joomla__TRuST__setup
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/bravo.example.test/docker-compose.yml" 'image: custom/joomla:stable'
  VDM_KEY=charlie
  VDM_J_REPO=joomla
  VDM_JV=latest
  joomla__TRuST__setup
  assert_file_contains "${VDM_SRC_PATH}/.env" 'VDM_DEFAULT_JOOMLA_IMAGE_SOURCE="custom/joomla"'
  # Setup's generated credentials never become input to another website.
  [ -z "${vdm_database_pass:-}" ]
}

@test "setup: existing shared environment key cannot silently change another site's credentials" {
  make_joomla_container bravo BRAVO bravo
  headless_setup
  VDM_ENV_KEY=BRAVO
  vdm_database_pass='different-secret'
  run joomla__TRuST__setup
  assert_status 17
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml"
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" 'VDM_BRAVO_DB_PASS="secret"'
}

@test "setup: literal credentials remain data and explicit values win after shared reload" {
  make_joomla_container bravo BRAVO bravo
  headless_setup
  vdm_database_pass='$(touch BAD)`id` $dollar "quote" \\slash'
  cliApplyValues() { VDM_J_REPO=custom/joomla; VDM_JV=release; }
  run joomla__TRuST__setup
  assert_success
  local saved
  migrationReadEnvValue "${VDM_REPO_PATH}/joomla/.env" VDM_ALPHA_DB_PASS saved
  assert_equal "$saved" "$vdm_database_pass"
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml" 'image: custom/joomla:release'
  refute_file_exists BAD
}

@test "setup: bulk automation uses one generator and keeps its named-volume defaults" {
  headless_setup
  VDM_TASK=bulk
  VDM_SUBDOMAIN=website
  VDM_NUMBER_CONTAINERS=2
  run joomla__TRuST__bulk
  assert_success
  assert_file_exists "${VDM_REPO_PATH}/joomla/available/website1.example.test/docker-compose.yml"
  assert_file_exists "${VDM_REPO_PATH}/joomla/available/website2.example.test/docker-compose.yml"
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/website3.example.test/docker-compose.yml"
  refute_command '^whiptail '
  refute_command '^docker compose .* up '
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" '_DB="vdm_io1"'
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" '_DB="vdm_io2"'
}

@test "setup: a different project path gets a complete scoped ENV without changing siblings" {
  make_joomla_container bravo BRAVO bravo
  cp "${VDM_REPO_PATH}/joomla/.env" "${SANDBOX}/before.env"
  headless_setup
  cliApplyValues() { VDM_PROJECT_PATH="${SANDBOX}/different projects"; }
  run joomla__TRuST__setup
  assert_success
  cmp "${SANDBOX}/before.env" "${VDM_REPO_PATH}/joomla/.env"
  local env_file="${VDM_REPO_PATH}/joomla/available/alpha.example.test/.env"
  assert_file_contains "$env_file" 'VDM_PROJECT_PATH='
  assert_file_contains "$env_file" 'different projects'
  assert_file_contains "$env_file" 'VDM_ALPHA_DB_PASS='
  run grep -q 'VDM_BRAVO_' "$env_file"
  assert_status 1
}

@test "setup: persisted image choices follow the final prepared runtime" {
  headless_setup
  VDM_WEBSERVER=nginx
  joomlaSetupWebPrepare() { VDM_JV=verified-fpm; }
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" 'VDM_ALPHA_IMAGE_TAG="verified-fpm"'
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml" 'image: joomla:verified-fpm'
}

@test "setup: explicit PHP settings run without probing unrelated webserver choices" {
  headless_setup
  parseCLI --memory-limit 512M --non-interactive
  joomlaSetupWebChoices() { printf 'unexpected webserver selection\n' >&2; return 91; }
  joomlaRuntimeRequireTools() { return 0; }
  joomlaRuntimeIniTarget() { printf '%s\n' /usr/local/etc/php/conf.d/zz-octojoom.ini; }
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "${VDM_PROJECT_PATH}/alpha/php.ini" 'memory_limit = 512M'
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml" '/usr/local/etc/php/conf.d/zz-octojoom.ini'
}

@test "setup: a headless webserver choice does not implicitly enable PHP overrides" {
  OCTOJOOM_NON_INTERACTIVE=true
  parseCLI --webserver nginx --non-interactive
  joomlaSetupDefaults
  assert_equal "$VDM_PHP_SETTINGS" false
}

@test "setup: contradictory PHP settings fail before first-run initialization" {
  local fresh="$SANDBOX/new-home"
  run env OCTOJOOM_HOME="$fresh" bash "$OCTOJOOM_SCRIPT" --type joomla --task setup \
    --key alpha --domain example.test --memory-limit 512M --php-settings false --non-interactive
  assert_status 17
  refute_file_exists "$fresh"
}

@test "setup: explicit manual installation ignores supplied administrator details" {
  headless_setup
  VDM_AUTO_INSTALL=false
  VDM_J_EMAIL=admin@example.test
  VDM_J_PASSWORD=secret-supplied-but-not-installed
  run joomla__TRuST__setup
  assert_success
  run grep -q JOOMLA_ADMIN_PASSWORD "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml"
  assert_status 1
}

@test "setup: automatic installation resolves Joomla version from a PHP alias tag" {
  headless_setup
  VDM_JV=php8.3-apache
  VDM_AUTO_INSTALL=true
  VDM_J_EMAIL=admin@example.test
  VDM_J_PASSWORD=secret-supplied-for-install
  joomlaRuntimeProbeImage() {
    printf '%s\n' "$1" >> "$SANDBOX/probed-images"
    printf '%s\n' '{"joomla":"5.3.2","php":"8.3.9","flavor":"apache"}'
  }
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml" 'image: joomla:php8.3-apache'
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.example.test/docker-compose.yml" 'JOOMLA_ADMIN_PASSWORD='
  [ "$(wc -l < "$SANDBOX/probed-images")" -eq 1 ]
}

@test "setup: an alias with an old Joomla release cannot silently auto-install" {
  headless_setup
  VDM_JV=legacy-custom
  VDM_AUTO_INSTALL=true
  VDM_J_EMAIL=admin@example.test
  VDM_J_PASSWORD=secret-supplied-for-install
  joomlaRuntimeProbeImage() { printf '%s\n' '{"joomla":"3.10.12"}'; }
  run joomlaSetupPreflight
  assert_status 17
  refute_file_exists "${VDM_REPO_PATH}/joomla/.env"
}

@test "setup: long project keys produce installer-compatible table prefixes" {
  headless_setup
  VDM_KEY=abcdefghijklmnopq
  VDM_AUTO_INSTALL=true
  VDM_J_EMAIL=admin@example.test
  VDM_J_PASSWORD=secret-supplied-for-install
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" 'VDM_ABCDEFGHIJKLMNOPQ_JOOMLA_DB_PREFIX="abcdefghijklmn_"'
}

@test "setup: an existing scoped table prefix is preserved exactly" {
  make_joomla_container bravo BRAVO bravo
  printf '%s\n' 'VDM_BRAVO_JOOMLA_DB_PREFIX="Legacy7_"' >> "${VDM_REPO_PATH}/joomla/.env"
  headless_setup
  VDM_ENV_KEY=BRAVO
  VDM_AUTO_INSTALL=true
  VDM_J_EMAIL=admin@example.test
  VDM_J_PASSWORD=secret-supplied-for-install
  run joomla__TRuST__setup
  assert_success
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" 'VDM_BRAVO_JOOMLA_DB_PREFIX="Legacy7_"'
}

@test "setup: an explicit bulk table prefix reaches every separate database" {
  headless_setup
  parseCLI --db-prefix Chosen9_ --non-interactive
  VDM_TASK=bulk
  VDM_SUBDOMAIN=website
  VDM_NUMBER_CONTAINERS=2
  VDM_AUTO_INSTALL=true
  VDM_J_EMAIL=admin@example.test
  VDM_J_PASSWORD=secret-supplied-for-install
  run joomla__TRuST__bulk
  assert_success
  [ "$(grep -c 'JOOMLA_DB_PREFIX="Chosen9_"' "${VDM_REPO_PATH}/joomla/.env")" -eq 2 ]
}

@test "setup: invalid explicit table prefixes fail before first-run filesystem changes" {
  local prefix fresh="$SANDBOX/new-home"
  for prefix in abcdefghijklmnop 9prefix_ invalid-prefix; do
    run env OCTOJOOM_HOME="$fresh" bash "$OCTOJOOM_SCRIPT" --type joomla --task setup \
      --key alpha --domain example.test --db-prefix "$prefix" --non-interactive
    assert_status 17
    refute_file_exists "$fresh"
  done
}
