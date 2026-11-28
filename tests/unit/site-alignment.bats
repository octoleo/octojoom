#!/usr/bin/env bats

# Test function globals and callbacks are consumed by the loaded application.
# shellcheck disable=SC2034,SC2154,SC2016,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container alpha ALPHA alpha example.test
  ALIGN_DIR="$VDM_REPO_PATH/joomla/available/alpha.example.test"
  ALIGN_YML="$ALIGN_DIR/docker-compose.yml"
  ALIGN_ENV="$VDM_REPO_PATH/joomla/.env"
}

@test "alignment: inspect has no writes or Docker calls, including with Docker unavailable" {
  cp "$ALIGN_YML" "$SANDBOX/original"
  fail_command docker-info 1
  run siteAlignConfiguration alpha.example.test inspect
  assert_success
  [[ "$output" == *$'pending\t'* ]]
  cmp "$ALIGN_YML" "$SANDBOX/original"
  [ ! -e "$ALIGN_DIR/.env" ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "alignment: missing setting reports its name and effective file without changing the site" {
  sed '/VDM_ALPHA_DB_ROOT=/d' "$ALIGN_ENV" > "$SANDBOX/incomplete.env"
  cp "$SANDBOX/incomplete.env" "$ALIGN_ENV"
  cp "$ALIGN_YML" "$SANDBOX/original"
  run siteAlignConfiguration alpha.example.test apply
  assert_failure
  assert_output_contains "Missing VDM_ALPHA_DB_ROOT in $ALIGN_ENV."
  assert_output_contains "Restore this setting's existing value, then retry."
  cmp "$ALIGN_YML" "$SANDBOX/original"
  cmp "$ALIGN_ENV" "$SANDBOX/incomplete.env"
  refute_file_exists "$ALIGN_DIR/.env"
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "alignment: CLI inspection and the selected website action accept operator settings in the shared env" {
  local site=alpha.example.test expected_health
  expected_health=$(joomlaServiceProperty "$ALIGN_YML" joomlaalpha healthcheck)
  VDM_WEB_HEALTH='["CMD", "curl", "-f", "http://localhost/"]' gen_joomla_compose alpha ALPHA alpha example.test > "$ALIGN_YML"
  printf 'VDM_ALPHA_BACKUP_RETENTION=7\nVDM_BETA_DB_PASS=sibling-secret\nVDM_HOST_PASSWORD=host-secret\n' >> "$ALIGN_ENV"
  awk '{print} END {for (i=NR; i<17; i++) print "# Host settings"; print "TZ=Africa/Windhoek"}' "$ALIGN_ENV" > "$SANDBOX/shared"
  cp "$SANDBOX/shared" "$ALIGN_ENV"
  cp "$ALIGN_YML" "$SANDBOX/before.yml"

  run_octojoom --type joomla --task align --container "$site" --action inspect --non-interactive
  assert_success
  assert_output_contains $'alpha.example.test\tpending\t'
  assert_output_contains 'Update the default Apache health check'
  cmp "$ALIGN_YML" "$SANDBOX/before.yml"
  cmp "$ALIGN_ENV" "$SANDBOX/shared"
  refute_file_exists "$ALIGN_DIR/.env"

  run runJoomlaSiteAction "$site" align
  assert_success
  assert_output_contains $'alpha.example.test\tupdated\t'
  assert_equal "$(joomlaServiceProperty "$ALIGN_YML" joomlaalpha healthcheck)" "$expected_health"
  assert_equal "$(siteReadServiceScalar "$ALIGN_YML" joomlaalpha image)" '${VDM_ALPHA_IMAGE}'
  local value
  migrationReadEnvValue "$ALIGN_DIR/.env" VDM_ALPHA_IMAGE value
  assert_equal "$value" joomla:5.3
  migrationReadEnvValue "$ALIGN_DIR/.env" VDM_ALPHA_DB_PASS value
  assert_equal "$value" secret
  migrationReadEnvValue "$ALIGN_DIR/.env" VDM_ALPHA_BACKUP_RETENTION value
  assert_equal "$value" 7
  refute_file_contains "$ALIGN_DIR/.env" 'TZ='
  refute_file_contains "$ALIGN_DIR/.env" 'VDM_BETA_'
  refute_file_contains "$ALIGN_DIR/.env" 'VDM_HOST_PASSWORD'
  cmp "$ALIGN_ENV" "$SANDBOX/shared"
}

@test "alignment: adding a literal image to a private env preserves its operator settings and comments" {
  cp "$ALIGN_ENV" "$ALIGN_DIR/.env"
  cat >> "$ALIGN_DIR/.env" <<'ENV'

# Keep the site's host-specific settings together.
TZ=Africa/Windhoek
VDM_LOCAL_NOTE='two words'
SITE_NOTE='Example setting:
VDM_ALPHA_IMAGE=example:only
'
ENV
  cp "$ALIGN_DIR/.env" "$SANDBOX/before.env"
  printf 'VDM_ALPHA_IMAGE="joomla:old"\n' >> "$ALIGN_DIR/.env"
  run_octojoom --type joomla --task align --container alpha.example.test --action apply --non-interactive
  assert_success
  assert_output_contains $'alpha.example.test\tupdated\t'
  assert_equal "$(siteReadServiceScalar "$ALIGN_YML" joomlaalpha image)" '${VDM_ALPHA_IMAGE}'
  assert_file_contains "$ALIGN_DIR/.env" 'VDM_ALPHA_IMAGE="joomla:5.3"'
  sed '/^VDM_ALPHA_IMAGE="joomla:5\.3"$/d' "$ALIGN_DIR/.env" > "$SANDBOX/after.env"
  cmp "$SANDBOX/before.env" "$SANDBOX/after.env"
}

@test "alignment: invalid quotes identify the setting and line without revealing its value" {
  printf '%s\n' 'VDM_ALPHA_DB_PASS="private-secret' >> "$ALIGN_ENV"
  local line_number
  line_number=$(awk 'END { print NR }' "$ALIGN_ENV")
  run siteAlignConfiguration alpha.example.test inspect
  assert_failure
  assert_output_contains "Invalid quoting for VDM_ALPHA_DB_PASS at $ALIGN_ENV:$line_number."
  [[ "$output" != *private-secret* ]]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "alignment: multiline value reports the unsupported format instead of a missing setting" {
  printf '%s\n' 'VDM_ALPHA_DB_PASS="private-secret\nsecond-line"' >> "$ALIGN_ENV"
  run siteAlignConfiguration alpha.example.test inspect
  assert_failure
  assert_output_contains 'Unsupported multiline value for VDM_ALPHA_DB_PASS'
  assert_output_contains 'Use a single-line value, then retry.'
  [[ "$output" != *private-secret* && "$output" != *second-line* ]]
}

@test "alignment: linked environment reports the path and reason instead of a missing setting" {
  mv "$ALIGN_ENV" "$SANDBOX/shared.env"
  ln -s "$SANDBOX/shared.env" "$ALIGN_ENV"
  [ -L "$ALIGN_ENV" ] || skip 'Symbolic links are unavailable'
  run siteAlignConfiguration alpha.example.test inspect
  assert_failure
  assert_output_contains "Environment file $ALIGN_ENV is a symbolic link."
  assert_output_contains 'Use a regular environment file, then retry.'
}

@test "scoped environment: referenced credentials and dormant site choices survive, sibling secrets do not" {
  {
    formatEnvAssignment 'VDM_ALPHA_SMTP_PASSWORD="saved $literal secret"'
    formatEnvAssignment 'VDM_ALPHA_PHP_MEMORY_LIMIT=512M'
    formatEnvAssignment 'VDM_ALPHA_HOOKS_ENABLED=false'
    formatEnvAssignment 'VDM_ALPHA_BACKUP_RETENTION=7'
    formatEnvAssignment 'VDM_BETA_DB_PASS=othersecret'
    formatEnvAssignment 'VDM_HOST_PASSWORD=hostsecret'
  } >> "$ALIGN_ENV"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/scoped.env"
  migrationValidateScopedEnv "$ALIGN_YML" "$SANDBOX/scoped.env"
  migrationReadEnvValue "$SANDBOX/scoped.env" VDM_ALPHA_SMTP_PASSWORD result
  assert_equal "$result" 'saved $literal secret'
  migrationReadEnvValue "$SANDBOX/scoped.env" VDM_ALPHA_HOOKS_ENABLED result
  assert_equal "$result" false
  run grep -qE 'BETA|HOST_PASSWORD' "$SANDBOX/scoped.env"
  assert_failure
  if ! is_windows; then assert_equal "$(file_mode "$SANDBOX/scoped.env")" 600; fi
  printf 'VDM_BETA_DB_PASS=othersecret\n' >> "$SANDBOX/scoped.env"
  run migrationValidateScopedEnv "$ALIGN_YML" "$SANDBOX/scoped.env"
  assert_failure
}

@test "scoped environment: missing required values leave destination intact" {
  sed '/VDM_ALPHA_DB_ROOT=/d' "$ALIGN_ENV" > "$SANDBOX/incomplete.env"
  printf 'previous\n' > "$SANDBOX/scoped.env"
  run siteWriteScopedEnv "$ALIGN_YML" "$SANDBOX/incomplete.env" ALPHA "$SANDBOX/scoped.env"
  assert_failure
  assert_equal "$(cat "$SANDBOX/scoped.env")" previous
}

@test "scoped environment: reapplying a setting keeps source record order and identical bytes" {
  printf 'VDM_ALPHA_SMTP_PORT=465\nVDM_ALPHA_HOOKS_ENABLED=false\n' >> "$ALIGN_ENV"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/first.env"
  printf 'VDM_ALPHA_SMTP_PORT="465"\nVDM_ALPHA_HOOKS_ENABLED="false"\n' > "$SANDBOX/last-two"
  tail -n 2 "$SANDBOX/first.env" | cmp "$SANDBOX/last-two" -
  writeEnvVariable "$SANDBOX/first.env" 'VDM_ALPHA_TLS_MODE="local"' true
  siteWriteScopedEnv "$ALIGN_YML" "$SANDBOX/first.env" ALPHA "$SANDBOX/reapplied.env"
  writeEnvVariable "$SANDBOX/reapplied.env" 'VDM_ALPHA_TLS_MODE="local"' true
  cmp "$SANDBOX/first.env" "$SANDBOX/reapplied.env"
}

@test "alignment: preserves custom fields and shared defaults, is idempotent and never starts disabled sites" {
  cat >> "$ALIGN_YML" <<'EXTRA'
x-user-notes:
  custom: keep this comment and extension
EXTRA
  cp "$ALIGN_ENV" "$SANDBOX/shared"
  run siteAlignConfiguration alpha.example.test apply
  assert_success
  [[ "$output" == *$'updated\t'* ]]
  assert_equal "$(siteReadServiceScalar "$ALIGN_YML" joomlaalpha image)" '${VDM_ALPHA_IMAGE}'
  migrationReadEnvValue "$ALIGN_DIR/.env" VDM_ALPHA_IMAGE image
  [[ "$image" == joomla:* ]]
  grep -q 'custom: keep this comment and extension' "$ALIGN_YML"
  cmp "$ALIGN_ENV" "$SANDBOX/shared"
  [ ! -e "$VDM_REPO_PATH/joomla/enabled/alpha.example.test" ]
  run grep -qE ' (up|stop|restart|pull) ' "$STUB_DIR/commands.log"
  assert_failure
  cp "$ALIGN_YML" "$SANDBOX/aligned"
  cp "$ALIGN_DIR/.env" "$SANDBOX/aligned.env"
  : > "$STUB_DIR/commands.log"
  run siteAlignConfiguration alpha.example.test apply
  assert_success
  [[ "$output" == *$'unchanged\t'* ]]
  cmp "$ALIGN_YML" "$SANDBOX/aligned"
  cmp "$ALIGN_DIR/.env" "$SANDBOX/aligned.env"
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "alignment: refused candidate validation leaves Compose and effective environment unchanged" {
  cp "$ALIGN_YML" "$SANDBOX/original"
  fail_command docker-compose-config 1
  run siteAlignConfiguration alpha.example.test apply
  assert_failure
  cmp "$ALIGN_YML" "$SANDBOX/original"
  [ ! -e "$ALIGN_DIR/.env" ]
}

@test "alignment: recreate only the selected running Apache service with the corrected probe" {
  local site=alpha.example.test
  siteAlignConfiguration "$site" apply
  printf '# Site-specific setting\nVDM_LOCAL_NOTE=keep\n' >> "$ALIGN_DIR/.env"
  cp "$ALIGN_DIR/.env" "$SANDBOX/private.env"
  cp "$ALIGN_YML" "$SANDBOX/current.yml"
  VDM_WEB_HEALTH='["CMD", "curl", "-f", "http://localhost/"]' gen_joomla_compose alpha ALPHA alpha example.test > "$SANDBOX/legacy.yml"
  joomlaServiceProperty "$SANDBOX/legacy.yml" joomlaalpha healthcheck > "$SANDBOX/legacy-probe"
  joomlaSetServiceProperty "$SANDBOX/current.yml" "$ALIGN_YML" joomlaalpha healthcheck "$SANDBOX/legacy-probe"
  mkdir -p "$VDM_REPO_PATH/joomla/available/other.example.test"
  printf 'unsupported layout\n' > "$VDM_REPO_PATH/joomla/available/other.example.test/docker-compose.yml"
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/requests"
    case " $* " in *' ps --status running --services '*) printf 'joomlaalpha\nmariadbalpha\n' ;; esac
  }
  VDM_CONTAINER="$site" VDM_ALL=false VDM_ACTION=inspect
  run joomla__TRuST__align
  assert_success
  assert_output_contains 'Update the default Apache health check'
  [ ! -s "$STUB_DIR/requests" ]
  VDM_ACTION=apply
  run joomla__TRuST__align
  assert_success
  cmp "$ALIGN_YML" "$SANDBOX/current.yml"
  cmp "$ALIGN_DIR/.env" "$SANDBOX/private.env"
  [ "$(grep -c ' up ' "$STUB_DIR/requests")" -eq 1 ]
  grep -q ' up -d --no-deps --force-recreate --wait --wait-timeout 90 joomlaalpha$' "$STUB_DIR/requests"
  : > "$STUB_DIR/requests"
  run joomla__TRuST__align
  assert_success
  assert_output_contains $'unchanged\t'
  [ ! -s "$STUB_DIR/requests" ]
}

@test "alignment: prepare a legacy probe on a stopped Apache container while preserving a custom probe" {
  local site=alpha.example.test legacy='["CMD", "curl", "-f", "http://localhost/"]'
  VDM_WEB_HEALTH="$legacy" gen_joomla_compose alpha ALPHA alpha example.test > "$ALIGN_YML"
  joomlaServiceProperty "$ALIGN_YML" joomlaalpha healthcheck > "$SANDBOX/legacy-probe"
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/requests"
    case " $* " in *' ps --all --services '*) printf 'joomlaalpha\n' ;; esac
  }
  run siteAlignConfiguration "$site" apply
  assert_success
  [ "$(grep -c ' up ' "$STUB_DIR/requests")" -eq 1 ]
  grep -q ' up --no-start --no-deps --force-recreate joomlaalpha$' "$STUB_DIR/requests"
  refute_file_contains "$ALIGN_YML" "$legacy"
  sed 's/interval: 30s/interval: 45s/' "$SANDBOX/legacy-probe" > "$SANDBOX/custom-probe"
  joomlaSetServiceProperty "$ALIGN_YML" "$SANDBOX/custom.yml" joomlaalpha healthcheck "$SANDBOX/custom-probe"
  cp "$SANDBOX/custom.yml" "$ALIGN_YML"
  : > "$STUB_DIR/requests"
  run siteAlignConfiguration "$site" apply
  assert_success
  assert_output_contains $'unchanged\t'
  cmp "$ALIGN_YML" "$SANDBOX/custom.yml"
  [ ! -s "$STUB_DIR/requests" ]
}

@test "alignment: unexpected effective semantic changes are refused without disclosing resolved secrets" {
  migrationRunCompose() {
    if [[ " $* " == *' --quiet '* ]]; then return 0; fi
    if [[ "$2" == *'.align-compose.'* ]]; then
      printf 'unexpected-secret\n'
    else
      printf 'previous-secret\n'
    fi
  }
  cp "$ALIGN_YML" "$SANDBOX/original"
  run siteAlignConfiguration alpha.example.test apply
  assert_failure
  [[ "$output" != *unexpected-secret* && "$output" != *previous-secret* ]]
  cmp "$ALIGN_YML" "$SANDBOX/original"
  [ ! -e "$ALIGN_DIR/.env" ]
}

@test "alignment: a shared Compose project name survives a probe-only repair and recreation" {
  VDM_WEB_HEALTH='["CMD", "curl", "-f", "http://localhost/"]' gen_joomla_compose alpha ALPHA alpha example.test > "$ALIGN_YML"
  printf 'COMPOSE_PROJECT_NAME=spark\n' >> "$ALIGN_ENV"
  cp "$ALIGN_ENV" "$SANDBOX/shared-before"
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/requests"
    case " $* " in
      *' config ') if grep -q '^COMPOSE_PROJECT_NAME=spark$' "$1"; then echo spark; else echo default; fi ;;
      *' ps --status running --services '*) echo joomlaalpha ;;
    esac
  }
  run siteAlignConfiguration alpha.example.test apply
  assert_success
  assert_output_contains 'Kept the current image and environment'
  assert_file_contains "$ALIGN_YML" '"OPTIONS"'
  assert_equal "$(siteReadServiceScalar "$ALIGN_YML" joomlaalpha image)" joomla:5.3
  refute_file_exists "$ALIGN_DIR/.env"
  cmp "$ALIGN_ENV" "$SANDBOX/shared-before"
  grep -F "$ALIGN_ENV $ALIGN_YML " "$STUB_DIR/requests" | grep -q ' up -d --no-deps --force-recreate .* joomlaalpha$'
}

@test "alignment: batch continues past unsupported site and reports partial failure" {
  mkdir -p "$VDM_REPO_PATH/joomla/available/custom.example.test"
  printf 'services: {}\n' > "$VDM_REPO_PATH/joomla/available/custom.example.test/docker-compose.yml"
  VDM_ALL=true VDM_CONTAINER='' VDM_ACTION=apply
  run joomla__TRuST__align
  assert_failure
  [[ "$output" == *$'alpha.example.test\tupdated\t'* ]]
  [[ "$output" == *$'custom.example.test\taction-needed\t'* ]]
  [ -f "$ALIGN_DIR/.env" ]
}

@test "scalar edit: only the selected service image changes and duplicate properties are refused" {
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/changed.yml" joomlaalpha image example/joomla:php-next
  assert_equal "$(siteReadServiceScalar "$SANDBOX/changed.yml" joomlaalpha image)" example/joomla:php-next
  assert_equal "$(siteReadServiceScalar "$SANDBOX/changed.yml" mariadbalpha image)" mariadb:latest
  awk '{ print } /    image: joomla:/ { print "    image: duplicate:tag" }' "$ALIGN_YML" > "$SANDBOX/duplicate.yml"
  run siteReplaceServiceScalar "$SANDBOX/duplicate.yml" "$SANDBOX/refused.yml" joomlaalpha image changed:tag
  assert_failure
}

@test "publication: failing runtime verification restores original files and prior service without touching database" {
  cp "$ALIGN_YML" "$SANDBOX/original"
  printf 'old directive\n' > "$ALIGN_DIR/php.ini"
  printf 'new directive\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/candidate.yml" joomlaalpha image candidate:tag
  OCTOJOOM_SITE_FILE_TARGETS=("$ALIGN_DIR/php.ini")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  OCTOJOOM_SITE_VALIDATE_FUNCTION=alignmentRejectRuntime
  alignmentRejectRuntime() { return 1; }
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/runtime-commands"
    case " $* " in *' ps '*) printf 'joomlaalpha\nmariadbalpha\n' ;; esac
  }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_failure
  cmp "$ALIGN_YML" "$SANDBOX/original"
  assert_equal "$(cat "$ALIGN_DIR/php.ini")" 'old directive'
  [ ! -e "$ALIGN_DIR/.env" ]
  run grep -E ' up .*mariadbalpha' "$STUB_DIR/runtime-commands"
  assert_failure
  [ "$(grep -c ' up ' "$STUB_DIR/runtime-commands")" -eq 2 ]
  [ "$(grep -c ' up .*--force-recreate' "$STUB_DIR/runtime-commands")" -eq 2 ]
  [ ! -e "$ALIGN_DIR/.octojoom-change.lock" ]
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: companion-only changes recreate the running web service" {
  printf 'memory_limit = 128M\n' > "$ALIGN_DIR/php.ini"
  printf 'memory_limit = 512M\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  cp "$ALIGN_YML" "$SANDBOX/candidate.yml"
  OCTOJOOM_SITE_FILE_TARGETS=("$ALIGN_DIR/php.ini")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/runtime-commands"
    case " $* " in *' ps '*) printf 'joomlaalpha\nmariadbalpha\n' ;; esac
  }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_success
  assert_equal "$(cat "$ALIGN_DIR/php.ini")" 'memory_limit = 512M'
  [ "$(grep -c ' up .*--force-recreate.*joomlaalpha' "$STUB_DIR/runtime-commands")" -eq 1 ]
  run grep -E ' up .*mariadbalpha' "$STUB_DIR/runtime-commands"
  assert_failure
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: project PHP overrides are updated in place and missing project folders are created" {
  local target="$VDM_PROJECT_PATH/site config/php.ini"
  printf 'max_execution_time = 300\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  cp "$ALIGN_YML" "$SANDBOX/candidate.yml"
  OCTOJOOM_SITE_PHP_FILE="$target"
  OCTOJOOM_SITE_FILE_TARGETS=("$target")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  migrationRunCompose() { return 0; }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_success
  assert_file_contains "$target" 'max_execution_time = 300'
  refute_file_exists "$ALIGN_DIR/php.ini"
  printf 'max_execution_time = 600\n' > "$SANDBOX/php.ini"
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_success
  assert_file_contains "$target" 'max_execution_time = 600'
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: an external companion must be the explicitly selected PHP file" {
  printf 'old\n' > "$VDM_PROJECT_PATH/php.ini"
  printf 'new\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  cp "$ALIGN_YML" "$SANDBOX/candidate.yml"
  OCTOJOOM_SITE_FILE_TARGETS=("$VDM_PROJECT_PATH/php.ini")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env"
  assert_failure
  assert_equal "$(cat "$VDM_PROJECT_PATH/php.ini")" old
}

@test "publication: failed project PHP apply restores its file and removes completed recovery" {
  local target="$VDM_PROJECT_PATH/php.ini"
  printf 'max_execution_time = 124\n' > "$target"
  printf 'max_execution_time = 300\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  cp "$ALIGN_YML" "$SANDBOX/candidate.yml"
  OCTOJOOM_SITE_PHP_FILE="$target"
  OCTOJOOM_SITE_FILE_TARGETS=("$target")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  OCTOJOOM_SITE_VALIDATE_FUNCTION=alignmentRejectRuntime
  alignmentRejectRuntime() { return 1; }
  migrationRunCompose() { case " $* " in *' ps '*) printf 'joomlaalpha\n' ;; esac; return 0; }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_failure
  assert_output_contains 'The previous configuration and service state were restored.'
  assert_file_contains "$target" 'max_execution_time = 124'
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: incomplete service recovery retains originals and reports their location" {
  cp "$ALIGN_YML" "$SANDBOX/original"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/candidate.yml" joomlaalpha image candidate:tag
  migrationRunCompose() {
    case " $* " in
      *' ps '*) printf 'joomlaalpha\n' ;;
      *' up '*) return 1 ;;
    esac
    return 0
  }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_failure
  assert_output_contains 'Automatic recovery is incomplete'
  local recovery
  recovery=$(compgen -G "$ALIGN_DIR/.octojoom-recovery.*")
  assert_output_contains "$recovery"
  cmp "$SANDBOX/original" "$recovery/1"
  cmp "$SANDBOX/original" "$ALIGN_YML"
  [ ! -e "$ALIGN_DIR/.octojoom-change.lock" ]
}

@test "publication: changed PHP files recreate existing stopped containers without starting them" {
  local target="$VDM_PROJECT_PATH/php.ini"
  printf 'max_execution_time = 124\n' > "$target"
  printf 'max_execution_time = 300\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  cp "$ALIGN_YML" "$SANDBOX/candidate.yml"
  OCTOJOOM_SITE_PHP_FILE="$target"
  OCTOJOOM_SITE_FILE_TARGETS=("$target")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/runtime-commands"
    case " $* " in *' ps --all --services '*) printf 'joomlaalpha\nmariadbalpha\n' ;; esac
    return 0
  }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_success
  assert_file_contains "$target" 'max_execution_time = 300'
  [ "$(grep -c ' up --no-start --no-deps --force-recreate joomlaalpha$' "$STUB_DIR/runtime-commands")" -eq 1 ]
  run grep -E ' up -d | up .*mariadbalpha' "$STUB_DIR/runtime-commands"
  assert_failure
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: failed stopped PHP recreation restores its file and leaves the site stopped" {
  local target="$VDM_PROJECT_PATH/php.ini"
  printf 'max_execution_time = 124\n' > "$target"
  printf 'max_execution_time = 300\n' > "$SANDBOX/php.ini"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  cp "$ALIGN_YML" "$SANDBOX/candidate.yml"
  OCTOJOOM_SITE_PHP_FILE="$target"
  OCTOJOOM_SITE_FILE_TARGETS=("$target")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  migrationRunCompose() {
    printf '%s\n' "$*" >> "$STUB_DIR/runtime-commands"
    case " $* " in
      *' ps --all --services '*) printf 'joomlaalpha\n' ;;
      *' up --no-start '*) grep -q '300' "$VDM_PROJECT_PATH/php.ini" && return 1 ;;
    esac
    return 0
  }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_failure
  assert_file_contains "$target" 'max_execution_time = 124'
  [ "$(grep -c ' up --no-start --no-deps --force-recreate joomlaalpha$' "$STUB_DIR/runtime-commands")" -eq 2 ]
  run grep -q ' up -d ' "$STUB_DIR/runtime-commands"
  assert_failure
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: copied enabled sites receive and recover the same configuration" {
  OS_NUMBER=3
  local enabled="$VDM_REPO_PATH/joomla/enabled/alpha.example.test"
  mkdir -p "${enabled%/*}"
  cp -R "$ALIGN_DIR" "$enabled"
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/candidate.yml" joomlaalpha image candidate:tag
  migrationRunCompose() { case " $* " in *' ps '*) printf 'joomlaalpha\n' ;; esac; return 0; }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_success
  cmp "$ALIGN_YML" "$enabled/docker-compose.yml"
  cmp "$ALIGN_DIR/.env" "$enabled/.env"
  assert_equal "$(getJoomlaSiteEnabledState alpha.example.test)" enabled
  cp "$ALIGN_YML" "$SANDBOX/previous"
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/candidate.yml" joomlaalpha image rejected:tag
  OCTOJOOM_SITE_VALIDATE_FUNCTION=alignmentRejectRuntime
  alignmentRejectRuntime() { return 1; }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_failure
  cmp "$SANDBOX/previous" "$ALIGN_YML"
  cmp "$ALIGN_YML" "$enabled/docker-compose.yml"
  cmp "$ALIGN_DIR/.env" "$enabled/.env"
  assert_equal "$(getJoomlaSiteEnabledState alpha.example.test)" enabled
  run compgen -G "$ALIGN_DIR/.octojoom-recovery.*"
  assert_failure
}

@test "publication: unavailable runtime state refuses mutation; stopped site saves without activation" {
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/candidate.yml" joomlaalpha image candidate:tag
  cp "$ALIGN_YML" "$SANDBOX/original"
  migrationRunCompose() { case " $* " in *' ps '*) return 1 ;; esac; return 0; }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_failure
  cmp "$ALIGN_YML" "$SANDBOX/original"
  migrationRunCompose() { printf '%s\n' "$*" >> "$STUB_DIR/runtime-commands"; }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env" joomlaalpha
  assert_success
  assert_equal "$(siteReadServiceScalar "$ALIGN_YML" joomlaalpha image)" candidate:tag
  run grep -q ' up ' "$STUB_DIR/runtime-commands"
  assert_failure
}

@test "publication: companion modes survive and a later rename failure rolls earlier files back" {
  skip_on_windows 'Unix file modes are not enforced on Git Bash'
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/candidate.env"
  siteReplaceServiceScalar "$ALIGN_YML" "$SANDBOX/candidate.yml" joomlaalpha image candidate:tag
  printf 'old\n' > "$ALIGN_DIR/php.ini"
  printf 'new\n' > "$SANDBOX/php.ini"
  chmod 644 "$SANDBOX/php.ini"
  OCTOJOOM_SITE_FILE_TARGETS=("$ALIGN_DIR/php.ini")
  OCTOJOOM_SITE_FILE_SOURCES=("$SANDBOX/php.ini")
  mv() {
    if [ "${*: -1}" = "$ALIGN_YML" ]; then return 1; fi
    command mv "$@"
  }
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env"
  assert_failure
  assert_equal "$(cat "$ALIGN_DIR/php.ini")" old
  [ ! -e "$ALIGN_DIR/.env" ]
  unset -f mv
  run sitePublishConfiguration alpha.example.test "$SANDBOX/candidate.yml" "$SANDBOX/candidate.env"
  assert_success
  assert_equal "$(file_mode "$ALIGN_DIR/php.ini")" 644
  assert_equal "$(file_mode "$ALIGN_DIR/.env")" 600
  assert_equal "$(file_mode "$ALIGN_YML")" 600
}

@test "scalar edit: a dotted service name is matched literally" {
  cat > "$SANDBOX/dotted.yml" <<'YAML'
services:
  web.site:
    image: intended:tag
  webXsite:
    image: neighbor:tag
YAML
  siteReplaceServiceScalar "$SANDBOX/dotted.yml" "$SANDBOX/changed.yml" web.site image changed:tag
  assert_equal "$(siteReadServiceScalar "$SANDBOX/changed.yml" web.site image)" changed:tag
  assert_equal "$(siteReadServiceScalar "$SANDBOX/changed.yml" webXsite image)" neighbor:tag
}

@test "scoped settings: clone keeps credential and PHP values when renaming the environment key" {
  formatEnvAssignment 'VDM_ALPHA_PHP_MEMORY_LIMIT=512M' >> "$ALIGN_ENV"
  : > "$SANDBOX/clone.env"
  cloneContainerEnvVariables "$ALIGN_ENV" ALPHA BETA "$SANDBOX/clone.env" >/dev/null
  migrationReadEnvValue "$SANDBOX/clone.env" VDM_BETA_DB_PASS cloned
  assert_equal "$cloned" secret
  migrationReadEnvValue "$SANDBOX/clone.env" VDM_BETA_PHP_MEMORY_LIMIT cloned
  assert_equal "$cloned" 512M
}

@test "alignment: retains the saved phpMyAdmin choice from website setup" {
  formatEnvAssignment 'VDM_ALPHA_PHPMYADMIN=false' >> "$ALIGN_ENV"
  run siteAlignConfiguration alpha.example.test apply
  assert_success
  migrationReadEnvValue "$ALIGN_DIR/.env" VDM_ALPHA_PHPMYADMIN choice
  assert_equal "$choice" false
  migrationValidateScopedEnv "$ALIGN_YML" "$ALIGN_DIR/.env"
}

@test "scoped environment: malformed dormant fields cannot bypass literal validation" {
  siteWriteScopedEnv "$ALIGN_YML" "$ALIGN_ENV" ALPHA "$SANDBOX/scoped.env"
  printf 'VDM_ALPHA_PHPMYADMIN="unterminated\n' >> "$SANDBOX/scoped.env"
  run migrationValidateScopedEnv "$ALIGN_YML" "$SANDBOX/scoped.env"
  assert_failure
}
