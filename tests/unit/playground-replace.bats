#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  bats_require_minimum_version 1.5.0
  octojoom_setup
  octojoom_config
  package="$SANDBOX/Shop's \$5 export.zip"
  prepared="$SANDBOX/prepared"
  site=shop.example.test
  make_joomla_container shop SHOP shop example.test
  write_playground_fixture "$package" fresh
}

# Record only the routing decision; the destructive operation has its own
# tests. Leaving the real CLI and whiptail dispatch in place catches bypasses.
record_replace() {
  joomlaPlaygroundDeployCurrent() {
    [ "$1" = "$package" ] && [ "$2" = "$site" ] || return 91
    printf '%s\n' "$3" "${4:-}" > "$SANDBOX/decision"
    printf '{"site":"%s","backup":%s}\n' "$2" "$3"
  }
}

replace_cli() {
  cliStart --type joomla --task playground --action deploy --target current --file "$package" \
    --non-interactive --output json "$@"
}

@test "replacement CLI requires an explicit site, replacement consent and a separate backup waiver" {
  record_replace
  run --separate-stderr replace_cli --confirm yes
  assert_status 17
  run --separate-stderr replace_cli --container "$site"
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --yes
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm no
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm yes --pre-backup no
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm yes --pre-backup no --confirm-no-backup no
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm yes --all
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --container other.example.test --confirm yes
  assert_status 17
  refute_file_exists "$SANDBOX/decision"
  refute_command '^docker '
}

@test "replacement CLI backs up by default and accepts an explicit double confirmation to skip" {
  record_replace
  # A saved setting cannot waive the backup for a later replacement request.
  export VDM_PRE_BACKUP=false VDM_CONFIRM_NO_BACKUP=true
  run --separate-stderr replace_cli --container "$site" --confirm yes
  assert_success
  joomlaSiteJSON -e '.success and .data.site=="shop.example.test" and .data.backup==true' <<< "$output"
  assert_equal "$(head -n 1 "$SANDBOX/decision")" true

  run --separate-stderr replace_cli --container "$site" --confirm yes --pre-backup no --confirm-no-backup yes
  assert_success
  joomlaSiteJSON -e '.success and .data.backup==false' <<< "$output"
  assert_equal "$(head -n 1 "$SANDBOX/decision")" false
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

record_yes_no_dialogs() {
  whiptail() {
    local flag default=Yes
    for flag in "$@"; do [ "$flag" != --defaultno ] || default=No; done
    case " $* " in
      *" --yesno "*)
        printf '%s | %s\n' "$default" "$*" >> "$SANDBOX/yesno";;
    esac
    command whiptail "$@"
  }
}

@test "No at the data loss warning asks the backup question again with Yes selected" {
  record_replace
  record_yes_no_dialogs
  answers "$package" current "$site" yes no no yes
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  assert_equal "$(head -n 1 "$SANDBOX/decision")" true
  local digest
  digest=$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)
  assert_equal "$(tail -n 1 "$SANDBOX/decision")" "$digest"
  # The warning defaults to No. The backup prompt keeps Yes selected when
  # presented a second time. All decisions use whiptail's two-button dialog.
  local defaults
  defaults=$(awk '/^(Yes|No) \| / {print $1}' "$SANDBOX/yesno")
  assert_equal "$defaults" $'No\nYes\nNo\nYes'
  assert_file_contains "$SANDBOX/yesno" "$site"
}

@test "Yes after declining the backup accepts data loss while declining replacement does nothing" {
  record_replace
  answers "$package" current "$site" no
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  refute_file_exists "$SANDBOX/decision"

  answers "$package" current "$site" yes no yes
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  assert_equal "$(head -n 1 "$SANDBOX/decision")" false
  refute_command '^docker '
}

@test "replacement revalidates the previewed archive before invoking the site transaction" {
  OCTOJOOM_OUTPUT=json
  local wrong_digest
  printf -v wrong_digest '%064d' 0
  joomlaPlaygroundReplaceSite() { touch "$SANDBOX/transaction-started"; }
  run --separate-stderr joomlaPlaygroundDeployCurrent "$package" "$site" true "$wrong_digest"
  assert_failure
  joomlaSiteJSON -e '.status=="failed" and .stage=="package" and .target=="current"' <<< "$output"
  refute_file_exists "$SANDBOX/transaction-started"
  refute_command '^docker '
}

@test "replacement configuration uses the target connection and mail policy with the imported title, secret and table prefix" {
  local original="$SANDBOX/current-configuration.php" candidate="$prepared/site/configuration.php"
  cat > "$original" <<'PHP'
<?php
class JConfig {
    public $sitename = 'Old title';
    public $secret = 'private-old-key';
    public $dbtype = 'mysqli';
    public $host = 'originaldb';
    public $db = 'old_db';
    public $user = 'old_user';
    public $password = 'old-password';
    public $dbprefix = 'old_';
    public $live_site = 'https://shop.example.test';
    public $log_path = '/srv/old/logs';
    public $tmp_path = '/srv/old/tmp';
    public $smtphost = 'smtp.example.test';
    public $smtppass = 'private-old-smtp-password';
    public $custom_policy = 'retain-target-setting';
}
PHP
  cp "$original" "$SANDBOX/prior.php"
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  parseCLI --non-interactive --site-name "Shop owner's site" --admin-password 'private-new-admin-password'
  local VDM_DB_NAME=new_db VDM_DB_USER=app_user VDM_DB_PASSWORD=private-new-db-password
  local vdm_database_name='' vdm_database_user='' vdm_database_pass=''
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_equal "$vdm_database_name" new_db
  assert_equal "$vdm_database_user" app_user
  assert_equal "$vdm_database_pass" private-new-db-password

  run joomlaPlaygroundConfigureReplace "$prepared" "$original" mariadbshop mysqli \
    "$vdm_database_name" "$vdm_database_user" "$vdm_database_pass" /var/www/html/public
  assert_success
  refute_output_contains private-
  cmp "$original" "$SANDBOX/prior.php"
  assert_file_contains "$candidate" 'private-fixture-key'
  refute_file_contains "$candidate" 'private-old-key'
  assert_file_contains "$candidate" 'retain-target-setting'
  assert_file_contains "$candidate" 'smtp.example.test'
  assert_file_contains "$candidate" 'private-old-smtp-password'
  assert_file_contains "$candidate" "Shop owner\\'s site"
  assert_file_contains "$candidate" 'mariadbshop'
  assert_file_contains "$candidate" 'new_db'
  assert_file_contains "$candidate" 'app_user'
  assert_file_contains "$candidate" 'private-new-db-password'
  assert_file_contains "$candidate" 'demo_'
  assert_file_contains "$candidate" '/var/www/html/public/administrator/logs'
  assert_file_contains "$candidate" '/var/www/html/public/tmp'
  refute_file_contains "$candidate" 'private-new-admin-password'
}

@test "candidate environment stores the confirmed administrator and database values privately" {
  local shared="$VDM_REPO_PATH/joomla/.env" candidate="$SANDBOX/site.env" value
  cp "$shared" "$SANDBOX/shared.before"
  printf 'VDM_SHOP_DOCROOT="public"\nVDM_SHOP_DB_ROOT="private-db-root"\n' > "$candidate"
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  local VDM_DB_NAME=old_db VDM_DB_USER=old_user VDM_DB_PASSWORD=private-old-db-password VDM_DB_DRIVER=mysqli
  parseCLI --non-interactive --site-name 'Replaced shop' --admin-user 'New owner' --admin-username administrator \
    --admin-email owner@example.test --admin-password 'private-new-admin-password' \
    --db-name shop_data --db-user shop_sql --db-password "private-\$site-password"
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  run joomlaPlaygroundReplaceEnv "$candidate" SHOP
  assert_success
  refute_output_contains private-
  migrationReadEnvValue "$candidate" VDM_SHOP_JOOMLA_SITE_NAME value
  assert_equal "$value" 'Replaced shop'
  migrationReadEnvValue "$candidate" VDM_SHOP_JOOMLA_ADMIN_USER value
  assert_equal "$value" 'New owner'
  migrationReadEnvValue "$candidate" VDM_SHOP_JOOMLA_ADMIN_USERNAME value
  assert_equal "$value" administrator
  migrationReadEnvValue "$candidate" VDM_SHOP_JOOMLA_ADMIN_EMAIL value
  assert_equal "$value" owner@example.test
  migrationReadEnvValue "$candidate" VDM_SHOP_JOOMLA_ADMIN_PASSWORD value
  assert_equal "$value" private-new-admin-password
  migrationReadEnvValue "$candidate" VDM_SHOP_JOOMLA_DB_PREFIX value
  assert_equal "$value" demo_
  migrationReadEnvValue "$candidate" VDM_SHOP_DB value
  assert_equal "$value" shop_data
  migrationReadEnvValue "$candidate" VDM_SHOP_DB_USER value
  assert_equal "$value" shop_sql
  migrationReadEnvValue "$candidate" VDM_SHOP_DB_PASS value
  # shellcheck disable=SC2016
  assert_equal "$value" 'private-$site-password'
  assert_file_contains "$candidate" private-db-root
  assert_file_contains "$candidate" public
  cmp "$shared" "$SANDBOX/shared.before"
}
