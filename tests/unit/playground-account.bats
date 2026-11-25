#!/usr/bin/env bats
load ../helpers/common

setup() {
  octojoom_setup
  command -v php >/dev/null || skip 'native PHP CLI is unavailable; Docker acceptance covers the imported Joomla account'
  mkdir -p "$SANDBOX/site/includes"
  : > "$SANDBOX/site/includes/defines.php"
  cp "$HELPERS_DIR/playground-account-framework.php" "$SANDBOX/site/includes/framework.php"
  account_code=$(joomlaPlaygroundImportAccountCode)
  settings='{"sourceUsername":"original","sourceEmail":"owner@example.test","explicitSource":false,
    "username":"owner","name":"Shop owner","email":"owner@example.test","password":"current-password",
    "changed":{"username":true,"email":false,"name":false,"password":false}}'
}

apply_account() {
  cd -- "$SANDBOX/site" || return 1
  joomlaSiteJSON "${1:-.}" <<< "$settings" | php -r "$account_code" -- . shop.example.test
}

@test "a confirmed renamed administrator keeps its ID when email and password are updated" {
  run apply_account '.email="new@example.test" | .password="new-password" | .changed.email=true | .changed.password=true'
  assert_success
  joomlaSiteJSON -e '.id==42 and .username=="owner" and .email=="new@example.test" and .newPasswordWorks' <<< "$output"

  run apply_account '.password="stale-export-password" | .name="Old display name" | .email="old@example.test"'
  assert_success
  assert_equal "$output" ''
}

@test "a confirmed edit preserves the imported hash and untouched email despite stale metadata" {
  run apply_account '.password="stale-export-password" | .email="old@example.test" | .name="Updated owner" | .changed.name=true'
  assert_success
  joomlaSiteJSON -e '.id==42 and .email=="owner@example.test" and .keptHash' <<< "$output"
}

@test "an explicit source account can be renamed independently of stale export metadata" {
  run apply_account '.sourceUsername="owner" | .explicitSource=true | .sourceEmail="old@example.test" | .username="shopmanager"'
  assert_success
  joomlaSiteJSON -e '.id==42 and .username=="shopmanager" and .keptHash' <<< "$output"

  run apply_account '.explicitSource=true'
  assert_equal "$status" 33
  assert_equal "$output" ''
}

@test "another imported user's login and a mismatched recovery email prevent any save" {
  run apply_account '.sourceUsername="owner" | .username="second-admin"'
  assert_equal "$status" 34
  assert_equal "$output" ''

  run apply_account '.sourceEmail="second-admin@example.test" | .changed.email=true'
  assert_equal "$status" 33
  assert_equal "$output" ''
}

@test "a renamed user must still be unblocked and permitted to log in to the administrator" {
  run apply_account '.username="blocked" | .sourceEmail="blocked@example.test"'
  assert_equal "$status" 31
  assert_equal "$output" ''

  run apply_account '.username="member" | .sourceEmail="member@example.test"'
  assert_equal "$status" 32
  assert_equal "$output" ''
}
