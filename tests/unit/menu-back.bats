#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  REAL_DOCKER=''
  export REAL_DOCKER
}

# Capture the actual first selectable item, independent of the placement of
# whiptail's window options. The usual stub still exercises each return path.
whiptail() {
  local -a arguments=("$@")
  local menu=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --menu) menu=true; shift 5;;
      --title|--backtitle|--default-item|--ok-button|--cancel-button) shift 2;;
      --fb|--nocancel|--notags|--scrolltext) shift;;
      *)
        if "$menu"; then printf '%s\n' "$1" >> "$SANDBOX/menu-first-items"; break; fi
        shift;;
    esac
  done
  command whiptail "${arguments[@]}"
}

@test "section menus keep Back as the first choice and return without running an action" {
  local menu
  for menu in showJoomla showOpenssh showTraefik showPortainer showSettings domainsMenu migrateMenu; do
    : > "$SANDBOX/menu-first-items"
    answers back
    run "$menu"
    assert_success
    assert_answers_used
    assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  done
  refute_command 'docker compose .* (up|down|stop|restart)'
}

@test "a long website chooser starts with Back and does not open a website" {
  listJoomlaSites() { printf 'site%s.example.test\n' {1..40}; }
  getJoomlaSiteEnabledState() { printf 'disabled\n'; }
  readJoomlaSiteFacts() { touch "$SANDBOX/unexpected-site"; return 1; }
  answers back
  run showJoomlaWebsiteInformation
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  refute_file_exists "$SANDBOX/unexpected-site"
}

@test "an empty website inventory still shows its notice without a Back-only chooser" {
  listJoomlaSites() { :; }
  run showJoomlaWebsiteInformation
  assert_success
  assert_answers_used
  assert_file_contains "$STUB_DIR/dialogs.full" 'There are no websites configured yet.'
  refute_file_exists "$SANDBOX/menu-first-items"
}

@test "logs start with Back before All services and do not read logs when returning" {
  readJoomlaSiteFacts() { VDM_SITE_SERVICES=$(printf 'service%s\n' {1..40}); }
  joomlaSiteCompose() { touch "$SANDBOX/unexpected-logs"; return 1; }
  answers back
  run runJoomlaSiteAction first.example.test logs
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  refute_file_exists "$SANDBOX/unexpected-logs"
}

@test "database tools start with Back and returning never runs a database operation" {
  joomlaDatabaseContext() { VDM_DB_NAME=example VDM_DB_ENGINE=mariadb VDM_DB_SERVICE=database; }
  joomla__TRuST__database() { touch "$SANDBOX/unexpected-database"; }
  answers back
  run showJoomlaDatabaseTools first.example.test
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  refute_file_exists "$SANDBOX/unexpected-database"
}

backup_menu_fixture() {
  joomlaBackupResolveOptions() { VDM_DESTINATION="$SANDBOX/backups"; }
  joomlaBackupList() {
    local index
    for index in {1..40}; do
      printf '2026-01-01\tfull\ttar.gz\t100\tBackup %s\t/archive/%s.tar.gz\n' "$index" "$index"
    done
  }
  joomla__TRuST__backup() { touch "$SANDBOX/unexpected-backup"; }
}

@test "backup actions start with Back and returning does not create a backup" {
  backup_menu_fixture
  answers back
  run showJoomlaBackups first.example.test
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  refute_file_exists "$SANDBOX/unexpected-backup"
}

@test "a long backup archive chooser starts with Back and returns to backup actions" {
  backup_menu_fixture
  answers verify back back
  run showJoomlaBackups first.example.test
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" $'back\nback\nback'
  [ "$(grep -c 'Backups for first.example.test' "$STUB_DIR/dialogs.full")" -eq 2 ]
  refute_file_exists "$SANDBOX/unexpected-backup"
}

@test "batch backup starts with Back and returning never gathers or backs up sites" {
  listJoomlaSites() { touch "$SANDBOX/unexpected-sites"; }
  joomla__TRuST__backup() { touch "$SANDBOX/unexpected-backup"; }
  answers back
  run showJoomlaBackupSelection
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  refute_file_exists "$SANDBOX/unexpected-sites"
  refute_file_exists "$SANDBOX/unexpected-backup"
}

@test "connection settings keep Back first without changing a connection" {
  joomlaTLSStatus() { printf 'Local HTTPS\n'; }
  showJoomlaTLSChange() { touch "$SANDBOX/unexpected-connection"; }
  answers back
  run showJoomlaTLS first.example.test
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/menu-first-items")" back
  refute_file_exists "$SANDBOX/unexpected-connection"
}
