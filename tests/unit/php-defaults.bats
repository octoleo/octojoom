#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config 'VDM_max_execution_time=300' 'VDM_memory_limit="768M"'
  OCTOJOOM_NON_INTERACTIVE=true
  VDM_SITE_DIR="$VDM_REPO_PATH/joomla/available/alpha.example.test"
  VDM_SITE_COMPOSE="$VDM_SITE_DIR/docker-compose.yml"
  VDM_SITE_ENV="$VDM_SITE_DIR/.env"
  PHP_SOURCE="$VDM_PROJECT_PATH/alpha/php.ini"
  PHP_HAS_MOUNT=true
  PHP_RUNNING=''
  mkdir -p "$VDM_SITE_DIR" "${PHP_SOURCE%/*}"
  printf 'VDM_ALPHA_DB=site\nVDM_ALPHA_PHP_CUSTOM=false\n' > "$VDM_SITE_ENV"
  printf 'services:\n  web:\n    image: joomla:latest\n    volumes:\n      - "%s:/usr/local/etc/php/conf.d/zz-octojoom.ini:ro"\n' "$PHP_SOURCE" > "$VDM_SITE_COMPOSE"
  readJoomlaSiteFacts() {
    VDM_SITE_SERVICE=web
    VDM_SITE_IMAGE=joomla:latest
    VDM_SITE_ENV_KEY=ALPHA
  }
  joomlaSiteCompose() {
    case " $* " in
      *' config --format json '*)
        if "$PHP_HAS_MOUNT"; then
          jq -n --arg source "$PHP_SOURCE" '{services:{web:{volumes:[{type:"bind",source:$source,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini"}]}}}'
        else printf '%s\n' '{"services":{"web":{"volumes":[{"type":"volume","source":"website","target":"/var/www/html"}]}}}'; fi;;
      *' ps --status running --services '*) printf '%s\n' "$PHP_RUNNING";;
      *) return 91;;
    esac
  }
  joomlaPHPIniDestination() { printf '%s\n' "$PHP_SOURCE"; }
  joomlaRuntimeIniTarget() { printf '%s\n' /usr/local/etc/php/conf.d/zz-octojoom.ini; }
  joomlaPHPValidateIni() { printf 'validated\n' >> "$SANDBOX/validation"; }
  sitePublishConfiguration() {
    [ "$OCTOJOOM_SITE_PHP_FILE" = "$PHP_SOURCE" ] || return 92
    [ "$OCTOJOOM_SITE_VALIDATE_FUNCTION" = joomlaPHPValidatePublished ] || return 93
    cp "${OCTOJOOM_SITE_FILE_SOURCES[0]}" "${OCTOJOOM_SITE_FILE_TARGETS[0]}" || return 1
    cp "$2" "$VDM_SITE_COMPOSE" && cp "$3" "$VDM_SITE_ENV" || return 1
    printf '%s\n' "$*" >> "$SANDBOX/publication"
  }
}

@test "PHP startup creates global defaults and a mount for an older site without an INI" {
  PHP_HAS_MOUNT=false
  printf 'services:\n  web:\n    image: joomla:latest\n    volumes:\n      - "website:/var/www/html"\n' > "$VDM_SITE_COMPOSE"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  assert_file_contains "$PHP_SOURCE" 'max_execution_time = 300'
  assert_file_contains "$PHP_SOURCE" 'memory_limit = 768M'
  local compose_php_source
  compose_php_source=$(joomlaWebHostPath "$PHP_SOURCE")
  assert_file_contains "$VDM_SITE_COMPOSE" "$compose_php_source:/usr/local/etc/php/conf.d/zz-octojoom.ini:ro"
  assert_file_contains "$VDM_SITE_ENV" 'VDM_ALPHA_PHP_CUSTOM=false'
  refute_command '^whiptail '
}

@test "PHP startup refreshes default-derived values and preserves unrelated directives" {
  printf 'max_execution_time = 124\nmemory_limit = 256M\ndate.timezone = Africa/Windhoek\n' > "$PHP_SOURCE"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  assert_file_contains "$PHP_SOURCE" 'max_execution_time = 300'
  assert_file_contains "$PHP_SOURCE" 'date.timezone = Africa/Windhoek'
  assert_file_exists "$SANDBOX/validation"
  assert_file_exists "$SANDBOX/publication"
}

@test "PHP startup does not publish or recreate an unchanged default file" {
  joomlaPHPWriteDefaults '' "$PHP_SOURCE"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  assert_equal "$output" ''
  refute_file_exists "$SANDBOX/validation"
  refute_file_exists "$SANDBOX/publication"
}

@test "PHP startup preserves custom and older unmarked settings" {
  printf 'max_execution_time = 900\nmemory_limit = 2G\n' > "$PHP_SOURCE"
  cp "$PHP_SOURCE" "$SANDBOX/custom.before"
  printf 'VDM_ALPHA_DB=site\nVDM_ALPHA_PHP_CUSTOM=true\n' > "$VDM_SITE_ENV"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  cmp "$SANDBOX/custom.before" "$PHP_SOURCE"
  printf 'VDM_ALPHA_DB=site\n' > "$VDM_SITE_ENV"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  cmp "$SANDBOX/custom.before" "$PHP_SOURCE"
  refute_file_exists "$SANDBOX/publication"
}

@test "PHP startup refuses to replace a missing custom file with unrelated defaults" {
  printf 'VDM_ALPHA_DB=site\nVDM_ALPHA_PHP_CUSTOM=true\n' > "$VDM_SITE_ENV"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_failure
  assert_output_contains 'custom PHP file'
  refute_file_exists "$PHP_SOURCE"
}

@test "PHP startup preserves an existing custom base INI and additional override" {
  printf 'VDM_ALPHA_DB=site\n' > "$VDM_SITE_ENV"
  printf 'memory_limit = 1G\n' > "$PHP_SOURCE"
  printf 'max_execution_time = 900\n' > "$SANDBOX/extra.ini"
  joomlaSiteCompose() {
    jq -n --arg source "$PHP_SOURCE" --arg extra "$SANDBOX/extra.ini" '{services:{web:{volumes:[
      {type:"bind",source:$source,target:"/usr/local/etc/php/php.ini"},
      {type:"bind",source:$extra,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini"}]}}}'
  }
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  assert_file_contains "$PHP_SOURCE" 'memory_limit = 1G'
  refute_file_exists "$SANDBOX/publication"
}

@test "PHP startup reports a recreated running service for lifecycle callers" {
  PHP_RUNNING=web
  printf 'max_execution_time = 124\n' > "$PHP_SOURCE"
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_success
  assert_equal "$output" web
  assert_file_contains "$SANDBOX/publication" ' web'
}

@test "PHP startup retains the original file if default validation fails" {
  printf 'max_execution_time = 124\n' > "$PHP_SOURCE"
  joomlaPHPValidateIni() { return 1; }
  run joomlaPHPEnsureSiteIni alpha.example.test
  assert_failure
  assert_file_contains "$PHP_SOURCE" 'max_execution_time = 124'
  refute_file_exists "$SANDBOX/publication"
}

@test "PHP lifecycle prepares start restart and redeploy but never changes settings during stop" {
  VDM_CONTAINER=alpha.example.test
  getJoomlaSiteEnabledState() { printf 'enabled\n'; }
  joomlaPHPEnsureSiteIni() { printf 'prepare\n' >> "$SANDBOX/prepare"; }
  joomlaSiteCompose() { printf '%s\n' "$*" >> "$SANDBOX/lifecycle"; }
  joomlaSiteLifecycle start
  joomlaSiteLifecycle restart
  joomlaSiteLifecycle redeploy
  joomlaSiteLifecycle stop
  [ "$(wc -l < "$SANDBOX/prepare")" -eq 3 ]
  assert_file_contains "$SANDBOX/lifecycle" 'alpha.example.test up -d'
  assert_file_contains "$SANDBOX/lifecycle" 'alpha.example.test restart'
  assert_file_contains "$SANDBOX/lifecycle" 'alpha.example.test up -d --force-recreate'
  assert_file_contains "$SANDBOX/lifecycle" 'alpha.example.test stop'
}

@test "PHP lifecycle does not restart PHP twice after refreshing a running service" {
  VDM_CONTAINER=alpha.example.test
  getJoomlaSiteEnabledState() { printf 'enabled\n'; }
  joomlaPHPEnsureSiteIni() { printf 'web\n'; }
  joomlaSiteCompose() {
    case " $* " in
      *' config --services '*) printf 'db\nweb\n';;
      *) printf '%s\n' "$*" >> "$SANDBOX/lifecycle";;
    esac
  }
  joomlaSiteLifecycle restart
  assert_equal "$(cat "$SANDBOX/lifecycle")" 'alpha.example.test restart db'
}

@test "PHP enable failure leaves the site disabled and does not start a container" {
  VDM_CONTAINER_TYPE=joomla
  VDM_CONTAINER=alpha.example.test
  joomlaPHPEnsureSiteIni() { return 19; }
  run joomla__TRuST__enable
  assert_status 19
  refute_file_exists "$VDM_REPO_PATH/joomla/enabled/alpha.example.test"
  refute_command '^docker compose .* up '
}
