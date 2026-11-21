#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container shop SHOP shop example.test
  original="$VDM_REPO_PATH/joomla/.env"
  compose="$VDM_REPO_PATH/joomla/available/shop.example.test/docker-compose.yml"
  candidate="$SANDBOX/candidate.env"
  published="$SANDBOX/published.env"
}

@test "replacement keeps proposed settings scoped and preserves neighboring shared settings and comments on publication" {
  cat >> "$original" <<'ENV'
# The next settings belong to another website.
VDM_OTHER_DB_PASS="private-neighbor-value" # Keep this comment.

# Preserve the selected site's comment and assignment layout too.
  export VDM_SHOP_JOOMLA_DB_PREFIX = "old_" # Keep the prefix note.
VDM_SHOP_AUTO_INSTALL=true
VDM_SHOP_CUSTOM="untouched # literal" # Unused custom setting.
ENV
  cp "$original" "$SANDBOX/before.env"
  if ! is_windows; then chmod 640 "$original"; fi
  siteWriteScopedEnv "$compose" "$original" SHOP "$candidate"
  refute_file_contains "$candidate" private-neighbor-value
  writeEnvVariable "$candidate" 'VDM_SHOP_JOOMLA_DB_PREFIX="new_"' true
  writeEnvVariable "$candidate" 'VDM_SHOP_AUTO_INSTALL=false' true
  writeEnvVariable "$candidate" 'VDM_SHOP_IMAGE_TAG="6.2.0-php8.4-apache"' true
  run joomlaPlaygroundPreparePublishedEnvironment "$original" "$candidate" SHOP "$published"
  assert_success
  [ -z "$output" ]
  cmp "$original" "$SANDBOX/before.env"
  sed -e 's/"old_" # Keep the prefix note./"new_" # Keep the prefix note./' \
    -e 's/^VDM_SHOP_AUTO_INSTALL=true$/VDM_SHOP_AUTO_INSTALL=false/' "$original" > "$SANDBOX/expected.env"
  printf 'VDM_SHOP_IMAGE_TAG="6.2.0-php8.4-apache"\n' >> "$SANDBOX/expected.env"
  cmp "$SANDBOX/expected.env" "$published"
  if ! is_windows; then assert_equal "$(file_mode "$published")" 640; fi
}

@test "environment publication preserves original comments once and round-trips literal quotes backslashes and dollars" {
  cat > "$original" <<'ENV'
# Keep the whole original file when selected values are unchanged.
VDM_SHOP_DB="shop_db" # Original database note.
VDM_SHOP_CUSTOM='custom # text' # Original custom note.
VDM_OTHER_DB_PASS="private-neighbor-value"
ENV
  cat > "$candidate" <<'ENV'
VDM_SHOP_DB="shop_db" # A proposed comment must not be duplicated.
VDM_SHOP_CUSTOM='custom # text' # A second proposed comment.
VDM_OTHER_DB_PASS="must-not-replace-the-neighbor"
ENV
  joomlaPlaygroundPreparePublishedEnvironment "$original" "$candidate" SHOP "$published"
  cmp "$original" "$published"
  rm "$published"
  printf 'VDM_SHOP_JOOMLA_ADMIN_PASSWORD="old" # Keep the password note.\n' >> "$original"
  local password='quote" and backslash\ and dollar$ and hash#' value
  writeEnvVariable "$candidate" "VDM_SHOP_JOOMLA_ADMIN_PASSWORD=\"$password\"" true
  joomlaPlaygroundPreparePublishedEnvironment "$original" "$candidate" SHOP "$published"
  migrationReadEnvValue "$published" VDM_SHOP_JOOMLA_ADMIN_PASSWORD value
  assert_equal "$value" "$password"
  assert_equal "$(grep -cF '# Keep the password note.' "$published")" 1
  assert_file_contains "$published" 'VDM_OTHER_DB_PASS="private-neighbor-value"'
  refute_file_contains "$published" must-not-replace-the-neighbor
}

@test "environment publication preserves CRLF comments and refuses a missing original or duplicate proposed key" {
  printf '# Existing environment\r\nVDM_SHOP_DB="old" # database\r\nVDM_OTHER_DB="neighbor"\r\n' > "$original"
  printf 'VDM_SHOP_DB="new"\n' > "$candidate"
  joomlaPlaygroundPreparePublishedEnvironment "$original" "$candidate" SHOP "$published"
  printf '# Existing environment\r\nVDM_SHOP_DB="new" # database\r\nVDM_OTHER_DB="neighbor"\r\n' > "$SANDBOX/expected.env"
  cmp "$SANDBOX/expected.env" "$published"
  rm "$published"
  run joomlaPlaygroundPreparePublishedEnvironment "$SANDBOX/missing.env" "$candidate" SHOP "$published"
  assert_failure
  refute_file_exists "$published"
  printf 'VDM_SHOP_DB="duplicate"\n' >> "$candidate"
  run joomlaPlaygroundPreparePublishedEnvironment "$original" "$candidate" SHOP "$published"
  assert_failure
  refute_file_exists "$published"
}

@test "atomic environment publication preserves its mode and cleans its temporary directory" {
  cp -p "$original" "$SANDBOX/expected.env"
  printf 'VDM_SHOP_JOOMLA_SITE_NAME="Imported shop"\n' > "$candidate"
  if ! is_windows; then chmod 640 "$original"; fi
  run joomlaPlaygroundInstallEnvironment "$candidate" "$original" "$SANDBOX/expected.env" "$original"
  assert_success
  cmp "$original" "$candidate"
  if ! is_windows; then assert_equal "$(file_mode "$original")" 640; fi
  assert_equal "$(find "${original%/*}" -maxdepth 1 -name '.octojoom-env.*' -print)" ''
}

@test "an interrupted environment or PHP copy leaves the installed file intact" {
  local destination
  printf 'VDM_SHOP_JOOMLA_SITE_NAME="Imported shop"\n' > "$candidate"
  runPrivileged() {
    if [ "$1" = cp ] && [ "${*: -2:1}" = "$candidate" ]; then
      printf 'interrupted copy' > "${*: -1}"
      return 1
    fi
    "$@"
  }
  for destination in "$original" "$SANDBOX/php.ini"; do
    [ -f "$destination" ] || printf 'precision = 15\n' > "$destination"
    cp -p "$destination" "$SANDBOX/expected.file"
    run joomlaPlaygroundInstallEnvironment "$candidate" "$destination" "$SANDBOX/expected.file" "$destination"
    assert_failure
    cmp "$destination" "$SANDBOX/expected.file"
    assert_equal "$(find "${destination%/*}" -maxdepth 1 -name '.octojoom-env.*' -print)" ''
  done
}

@test "atomic PHP creation requires the destination to be absent and preserves an existing file" {
  local destination="$SANDBOX/new-php.ini"
  printf 'precision = 15\n' > "$candidate"
  run joomlaPlaygroundInstallEnvironment "$candidate" "$destination" - "$candidate"
  assert_success
  cmp "$candidate" "$destination"
  printf '; operator edit\n' >> "$destination"
  cp "$destination" "$SANDBOX/expected.ini"
  run joomlaPlaygroundInstallEnvironment "$candidate" "$destination" - "$candidate"
  assert_failure
  cmp "$destination" "$SANDBOX/expected.ini"
  assert_equal "$(find "$SANDBOX" -maxdepth 1 -name '.octojoom-env.*' -print)" ''
}

@test "atomic PHP creation preserves a destination created while its temporary copy is prepared" {
  local destination="$SANDBOX/new-php.ini"
  printf 'precision = 15\n' > "$candidate"
  runPrivileged() {
    if [ "$1" = cp ] && [ "${*: -2:1}" = "$candidate" ]; then
      printf '; concurrent operator file\n' > "$destination"
    fi
    "$@"
  }
  run joomlaPlaygroundInstallEnvironment "$candidate" "$destination" - "$candidate"
  assert_failure
  assert_equal "$(cat "$destination")" '; concurrent operator file'
  assert_equal "$(find "$SANDBOX" -maxdepth 1 -name '.octojoom-env.*' -print)" ''
}

@test "an operator environment edit during publication is preserved" {
  cp -p "$original" "$SANDBOX/expected.env"
  printf 'VDM_SHOP_JOOMLA_SITE_NAME="Imported shop"\n' > "$candidate"
  runPrivileged() {
    if [ "$1" = cp ] && [ "${*: -2:1}" = "$candidate" ]; then
      printf 'VDM_OTHER_NOTE="edit at publication"\n' >> "$original"
    fi
    "$@"
  }
  run joomlaPlaygroundInstallEnvironment "$candidate" "$original" "$SANDBOX/expected.env" "$original"
  assert_failure
  assert_output_contains 'environment changed'
  assert_file_contains "$original" 'VDM_OTHER_NOTE="edit at publication"'
  refute_file_contains "$original" 'Imported shop'
  assert_equal "$(find "${original%/*}" -maxdepth 1 -name '.octojoom-env.*' -print)" ''
}
