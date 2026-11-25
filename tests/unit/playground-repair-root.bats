#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container shop SHOP shop example.test
  VDM_PLAYGROUND_REPAIR=true
  shared_env="$VDM_REPO_PATH/joomla/.env"
  tree="$VDM_PROJECT_PATH/shop/joomla"
  mkdir -p "$tree/host/store" "$tree/host/sibling"
  echo 'keep me' > "$tree/host/sibling/data"
  jq -n --arg tree "$tree" '{services:{app:{image:"joomla:latest",environment:{JOOMLA_DB_HOST:"db"},volumes:[{type:"bind",source:$tree,target:"/var/www/html"}]},db:{image:"mariadb:latest"}}}' > "$SANDBOX/model"
  joomlaSiteCompose() {
    [ "$1" = shop.example.test ] && [ "$2" = config ] && cat "$SANDBOX/model"
  }
}

@test "repair retains only the selected nested document root even among custom shared records" {
  cat >> "$shared_env" <<'ENV'
MY_TAG='custom'
LONG_VALUE='arbitrary text
VDM_SHOP_DOCROOT=.
'
VDM_SIBLING_DOCROOT=host/sibling
VDM_SHOP_DOCROOT="host/store" # actual selected site
ENV
  readJoomlaSiteFacts shop.example.test
  assert_equal "$VDM_SITE_DOCROOT" /var/www/html/host/store
  assert_equal "$VDM_SITE_HOST_PATH" "$tree/host/store"
  assert_file_contains "$tree/host/sibling/data" 'keep me'
}

@test "repair refuses ambiguous or unusable saved roots before selecting a broader directory" {
  cp "$shared_env" "$SANDBOX/env-before"
  local input
  for input in 'VDM_SHOP_DOCROOT="../wrong"' 'VDM_SHOP_DOCROOT=' 'VDM_SHOP_DOCROOT="bad' \
    $'VDM_SHOP_DOCROOT="first\nline"' $'VDM_SHOP_DOCROOT=host/store\nVDM_SHOP_DOCROOT=.'; do
    cp "$SANDBOX/env-before" "$shared_env"
    printf '%s\n' 'NORMAL=custom' "$input" >> "$shared_env"
    run readJoomlaSiteFacts shop.example.test
    assert_failure
    assert_output_contains 'Cannot resolve one document root'
    assert_file_contains "$tree/host/sibling/data" 'keep me'
  done
}

@test "repair infers the selected Compose root and stops when explicit root declarations disagree" {
  jq '.services.app.working_dir="/var/www/html/host/store/" | .services.app.environment.APACHE_DOCUMENT_ROOT="/var/www/html/host/store"' "$SANDBOX/model" > "$SANDBOX/updated"
  mv "$SANDBOX/updated" "$SANDBOX/model"
  readJoomlaSiteFacts shop.example.test
  assert_equal "$VDM_SITE_HOST_PATH" "$tree/host/store"
  echo 'VDM_SHOP_DOCROOT=.' >> "$shared_env"
  run readJoomlaSiteFacts shop.example.test
  assert_failure
  assert_output_contains 'Cannot resolve one document root'
}
