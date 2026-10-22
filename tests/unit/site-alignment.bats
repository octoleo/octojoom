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

@test "alignment: malformed assignment reports its actual line without revealing its contents" {
  printf '%s\n' 'BROKEN-private-secret' >> "$ALIGN_ENV"
  local line_number
  line_number=$(awk 'END { print NR }' "$ALIGN_ENV")
  run siteAlignConfiguration alpha.example.test inspect
  assert_failure
  assert_output_contains "Invalid assignment at $ALIGN_ENV:$line_number."
  assert_output_contains 'Use VDM_NAME=value or a comment, then retry.'
  [[ "$output" != *private-secret* && "$output" != *'Missing VDM_'* ]]
  [ ! -s "$STUB_DIR/commands.log" ]
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
