#!/usr/bin/env bats
# Each Bats case recreates its own PHP fixture and variable scope.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE=joomla
  OCTOJOOM_NON_INTERACTIVE=true
  export OCTOJOOM_NON_INTERACTIVE
  cliHasValue() { [[ " ${OCTOJOOM_TEST_REQUEST:-} " == *" $1 "* ]]; }
}

@test "PHP image sources preserve registry ports and do not invent another repository" {
  run joomlaRuntimeRepository registry.example:5000/company/runtime:8-apache
  assert_success
  assert_equal "$output" registry.example:5000/company/runtime
  run joomlaRuntimeRepository octoleo/joomengine@sha256:1234
  assert_equal "$output" octoleo/joomengine
}

@test "PHP INI patches isolate a shared file and preserve unrelated settings" {
  local original="$SANDBOX/shared php.ini" changed="$SANDBOX/site.ini"
  printf '; developer configuration\ndate.timezone = Africa/Windhoek\nmemory_limit = 128M\nmax_execution_time = 60\n' > "$original"
  run joomlaPHPPatchIni "$original" "$changed" memory_limit 512M max_input_vars 4000
  assert_success
  assert_file_contains "$original" 'memory_limit = 128M'
  assert_file_contains "$changed" 'memory_limit = 512M'
  assert_file_contains "$changed" 'max_input_vars = 4000'
  assert_file_contains "$changed" 'date.timezone = Africa/Windhoek'
  assert_file_contains "$changed" '; developer configuration'
  assert_equal "$(grep -c '^memory_limit' "$changed")" 1
}

@test "PHP settings reject executable-looking values and preserve explicit zero" {
  run joomlaPHPValidateValue memory_limit '512M; auto_prepend_file=/evil.php'
  assert_failure
  run joomlaPHPValidateValue error_reporting '$(touch /tmp/unsafe)'
  assert_failure
  run joomlaPHPValidateValue max_execution_time 0
  assert_success
  OCTOJOOM_TEST_REQUEST=VDM_max_execution_time
  VDM_max_execution_time=0
  run joomlaPHPQuestion max_execution_time 124
  assert_success
  assert_equal "$output" 0
  refute_command 'whiptail'
}

@test "PHP mount edit changes one selected service and keeps siblings and custom fields" {
  local source="$SANDBOX/compose.yml" target="$SANDBOX/new.yml"
  cat > "$source" <<'YAML'
services:
  joomlafirst:
    image: custom/runtime:old
    entrypoint: /custom-entrypoint.sh
    volumes:
      - "shared_php:/var/www/html"
      - "/host/shared/php.ini:/var/www/html/php.ini"
    labels:
      - "custom.label=retained"
  joomlasecond:
    image: custom/runtime:old
    volumes:
      - "/host/shared/php.ini:/var/www/html/php.ini"
YAML
  run joomlaPHPReplaceMount "$source" "$target" joomlafirst /var/www/html/php.ini '/host/site one/php.ini' /custom/php/conf.d/zz-octojoom.ini
  assert_success
  assert_file_contains "$target" '"/host/site one/php.ini:/custom/php/conf.d/zz-octojoom.ini:ro"'
  assert_file_contains "$target" 'entrypoint: /custom-entrypoint.sh'
  assert_file_contains "$target" '"custom.label=retained"'
  assert_file_contains "$target" '"shared_php:/var/www/html"'
  assert_equal "$(grep -c '"/host/shared/php.ini:/var/www/html/php.ini"' "$target")" 1
}

@test "PHP mount edit refuses ambiguous or non-block mounts without overwriting source" {
  local source="$SANDBOX/compose.yml" target="$SANDBOX/new.yml"
  printf 'services:\n  web:\n    volumes: ["data:/var/www/html"]\n' > "$source"
  run joomlaPHPReplaceMount "$source" "$target" web '' /host/php.ini /php/conf.d/zz-octojoom.ini
  assert_failure
  refute_file_exists "$target"
  assert_file_contains "$source" 'volumes: ['
}

@test "PHP candidate validation refuses core upgrades and mismatched architecture" {
  readJoomlaSiteFacts() { VDM_SITE_IMAGE=joomla:current; }
  joomlaRuntimeInstalledVersion() { echo 6.1.4; }
  joomlaRuntimeProbeImage() {
    local version=6.1.4
    [[ "$1" != joomla:newcore ]] || version=7.0.0
    printf '{"joomla":"%s","php":"8.4.1","flavor":"apache","extensions":["json","session","dom","SimpleXML","xml","mbstring","mysqli"]}\n' "$version"
  }
  docker() {
    if [ "$1 $2" = 'image inspect' ]; then
      if [[ "${*: -1}" == joomla:otherarch ]]; then echo linux/arm64; else echo linux/amd64; fi
    fi
  }
  run joomlaRuntimeSelectImage example.test apache newcore
  assert_failure
  assert_output_contains 'Candidate must contain Joomla 6.1.4'
  run joomlaRuntimeSelectImage example.test apache otherarch
  assert_failure
  assert_output_contains 'architecture does not match'
  run joomlaRuntimeSelectImage example.test apache valid
  assert_success
  assert_equal "$output" joomla:valid
}

@test "PHP candidate validation retains source and checks extensions and webserver PHP" {
  readJoomlaSiteFacts() { VDM_SITE_IMAGE=vendor/custom:current; }
  joomlaRuntimeInstalledVersion() { echo 5.4.0; }
  joomlaRuntimeProbeImage() {
    case "$1" in
      *current) echo '{"php":"8.3.9","flavor":"apache","extensions":[]}' ;;
      *missing) echo '{"joomla":"5.4.0","php":"8.4.1","flavor":"apache","extensions":["json"]}' ;;
      *) echo '{"joomla":"5.4.0","php":"8.4.1","flavor":"fpm","extensions":["json","session","dom","SimpleXML","xml","mbstring","mysqli"]}' ;;
    esac
  }
  run joomlaRuntimeSelectImage example.test apache another/image:tag
  assert_failure
  assert_output_contains 'retain image repository'
  run joomlaRuntimeSelectImage example.test apache missing
  assert_failure
  assert_output_contains 'required PHP extensions'
  run joomlaRuntimeSelectImage example.test fpm candidate
  assert_failure
  assert_output_contains 'must retain PHP 8.3'
}

@test "PHP INI target comes from the runtime scan directory" {
  joomlaRuntimeProbeImage() { echo '{"ini_dir":"/opt/vendor/php/conf.d"}'; }
  run joomlaRuntimeIniTarget custom/php:tag
  assert_success
  assert_equal "$output" /opt/vendor/php/conf.d/zz-octojoom.ini
  joomlaRuntimeProbeImage() { echo '{"ini_dir":"/first:/second"}'; }
  run joomlaRuntimeIniTarget custom/php:tag
  assert_failure
}

@test "PHP image probe overrides installation entrypoint and never mounts the live website" {
  hook_command docker <<'SH'
printf '%s\n' "$@" > "$STUB_DIR/probe-args"
printf '%s\n' '{"joomla":"6.1.4","php":"8.3.1","flavor":"apache","ini_dir":"/php/conf.d","extensions":[]}'
SH
  run joomlaRuntimeProbeImage custom/runtime:latest
  assert_success
  assert_file_contains "$STUB_DIR/probe-args" --read-only
  assert_file_contains "$STUB_DIR/probe-args" --entrypoint
  assert_file_contains "$STUB_DIR/probe-args" --network
  refute_file_contains "$STUB_DIR/probe-args" --mount
}

@test "PHP settings action never mutates host defaults or a shared bulk INI" {
  local site=example.test stage="$SANDBOX/stage"
  mkdir -p "$stage" "$SANDBOX/site"
  VDM_SITE_DIR="$SANDBOX/site"
  VDM_SITE_COMPOSE="$VDM_SITE_DIR/docker-compose.yml"
  VDM_SITE_SERVICE=web
  VDM_SITE_ENV_KEY=EXAMPLE
  VDM_SITE_IMAGE=custom/php:tag
  VDM_SITE_RUNNING=stopped
  VDM_memory_limit=512M
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  printf 'VDM_memory_limit="128M"\n' > "$VDM_SRC_PATH/.env"
  mkdir -p "$VDM_PROJECT_PATH/bulk"
  printf 'memory_limit = 128M\ndate.timezone = UTC\n' > "$VDM_PROJECT_PATH/bulk/php.ini"
  printf 'services:\n  web:\n    volumes:\n      - "%s:/var/www/html/php.ini"\n' "$VDM_PROJECT_PATH/bulk/php.ini" > "$VDM_SITE_COMPOSE"
  : > "$stage/.env"
  joomlaRuntimeIniTarget() { echo /php/conf.d/zz-octojoom.ini; }
  joomlaSiteCompose() { printf '{"services":{"web":{"volumes":[{"type":"bind","source":"%s/bulk/php.ini","target":"/var/www/html/php.ini"}]}}}\n' "$VDM_PROJECT_PATH"; }
  run joomlaPHPSettingsAction "$site" "$stage"
  assert_success
  assert_file_contains "$VDM_SRC_PATH/.env" 'VDM_memory_limit="128M"'
  assert_file_contains "$VDM_PROJECT_PATH/bulk/php.ini" 'memory_limit = 128M'
  assert_file_contains "$stage/php.ini" 'memory_limit = 512M'
  assert_file_contains "$stage/php.ini" 'date.timezone = UTC'
  assert_file_contains "$stage/.env" 'VDM_EXAMPLE_PHP_MEMORY_LIMIT=512M'
  assert_file_contains "$stage/docker-compose.yml" "$(joomlaWebHostPath "$VDM_PROJECT_PATH/example.test/php.ini"):/php/conf.d/zz-octojoom.ini:ro"
  assert_file_contains "$stage/.env" 'VDM_EXAMPLE_PHP_CUSTOM=true'
}

@test "PHP installed-version inspection never creates an unknown named volume" {
  readJoomlaSiteFacts() {
    VDM_SITE_MOUNT_TYPE=volume
    VDM_SITE_MOUNT_SOURCE=webfiles
    VDM_SITE_VOLUME_NAME=''
    VDM_SITE_MOUNT_TARGET=/var/www/html
    VDM_SITE_DOCROOT=/var/www/html
    VDM_SITE_IMAGE=joomla:current
  }
  run joomlaRuntimeInstalledVersion example.test
  assert_failure
  refute_command '^docker run'
  readJoomlaSiteFacts() {
    VDM_SITE_MOUNT_TYPE=volume
    VDM_SITE_MOUNT_SOURCE=webfiles
    VDM_SITE_VOLUME_NAME=project_webfiles
    VDM_SITE_MOUNT_TARGET=/var/www/html
    VDM_SITE_DOCROOT=/var/www/html
    VDM_SITE_IMAGE=joomla:current
  }
  hook_command docker <<'SH'
if [ "$1" = volume ]; then exit 1; fi
exit 99
SH
  run joomlaRuntimeInstalledVersion example.test
  assert_failure
  assert_command '^docker volume inspect project_webfiles$'
  refute_command '^docker run'
}

@test "PHP global INI changes retain deliberate HOST and PATH overrides" {
  local source="$SANDBOX/scoped.ini" target="$SANDBOX/patched.ini"
  printf '; settings\nmemory_limit = 128M\n[PATH=/var/www/html/admin]\nmemory_limit = 1G\n[Date]\ndate.timezone = UTC\n' > "$source"
  run joomlaPHPPatchIni "$source" "$target" memory_limit 512M
  assert_success
  assert_equal "$(head -n 1 "$target")" 'memory_limit = 512M'
  assert_file_contains "$target" 'memory_limit = 1G'
  refute_file_contains "$target" 'memory_limit = 128M'
  assert_file_contains "$target" 'date.timezone = UTC'
}

@test "keeping the current webserver preserves its floating tag without registry lookup" {
  joomlaRuntimeProbeImage() { echo '{"joomla":"6.1.4","php":"8.3.1","flavor":"apache"}'; }
  joomlaRuntimeTags() { echo 'Registry must not be queried' >&2; return 99; }
  run joomlaRuntimeSelectImageForFlavor vendor/custom:latest apache
  assert_success
  assert_equal "$output" vendor/custom:latest
}

@test "invalid native PHP settings stop before a proposed mount is published" {
  local stage="$SANDBOX/stage"
  mkdir -p "$stage" "$SANDBOX/site"
  VDM_SITE_DIR="$SANDBOX/site"
  VDM_SITE_COMPOSE="$VDM_SITE_DIR/docker-compose.yml"
  VDM_SITE_SERVICE=web
  VDM_SITE_ENV_KEY=EXAMPLE
  VDM_SITE_IMAGE=custom/php:tag
  VDM_SITE_RUNNING=stopped
  VDM_error_reporting='E_ALL &'
  OCTOJOOM_TEST_REQUEST=VDM_error_reporting
  printf 'services:\n  web:\n    volumes:\n      - "website:/var/www/html"\n' > "$VDM_SITE_COMPOSE"
  : > "$stage/.env"
  joomlaRuntimeIniTarget() { echo /php/conf.d/zz-octojoom.ini; }
  joomlaSiteCompose() { echo '{"services":{"web":{"volumes":[]}}}'; }
  joomlaPHPValidateIni() { return 1; }
  run joomlaPHPSettingsAction example.test "$stage"
  assert_failure
  refute_file_exists "$stage/docker-compose.yml"
  refute_file_exists "$VDM_SITE_DIR/php.ini"
  assert_file_contains "$VDM_SITE_COMPOSE" '"website:/var/www/html"'
}

@test "PHP switches preserve bulk overrides while moving only this site's scan mount" {
  local stage="$SANDBOX/stage" shared="$VDM_PROJECT_PATH/bulk/php.ini"
  mkdir -p "$stage" "$SANDBOX/site" "${shared%/*}"
  VDM_SITE_DIR="$SANDBOX/site"
  VDM_SITE_SERVICE=web
  printf 'memory_limit = 512M\ndate.timezone = Africa/Windhoek\n' > "$shared"
  printf 'services:\n  web:\n    image: custom/php:new\n    volumes:\n      - "%s:/var/www/html/php.ini"\n' "$shared" > "$stage/docker-compose.yml"
  joomlaSiteCompose() { printf '{"services":{"web":{"volumes":[{"type":"bind","source":"%s","target":"/var/www/html/php.ini"}]}}}\n' "$shared"; }
  joomlaRuntimeIniTarget() { echo /new/php/conf.d/zz-octojoom.ini; }
  joomlaPHPValidateIni() { return 0; }
  run joomlaPHPStageExistingOverrides example.test "$stage" custom/php:new
  assert_success
  assert_file_contains "$stage/docker-compose.yml" 'image: custom/php:new'
  assert_file_contains "$stage/docker-compose.yml" "$(joomlaWebHostPath "$VDM_PROJECT_PATH/example.test/php.ini"):/new/php/conf.d/zz-octojoom.ini:ro"
  assert_equal "$(cat "$shared")" "$(cat "$stage/php.ini")"
}

@test "published tags fall back from Hub denial to authenticated paginated registry discovery" {
  curl() {
    local headers='' previous='' arg
    for arg in "$@"; do
      [ "$previous" != --dump-header ] || headers="$arg"
      previous="$arg"
    done
    case "${*: -1}" in
      https://hub.docker.com/*) return 22;;
      https://auth.docker.io/token\?*) printf '{"token":"anonymous-repository-token"}\n';;
      *tags/list\?n=1000)
        printf 'HTTP/2 200\r\nLink: </v2/library/joomla/tags/list?n=1000&last=5.4.0-php8.3-apache>; rel="next"\r\n' > "$headers"
        printf '{"name":"library/joomla","tags":["5.4.0-php8.3-apache"]}\n';;
      *tags/list\?n=1000\&last=*)
        printf 'HTTP/2 200\r\n' > "$headers"
        printf '{"name":"library/joomla","tags":["5.4.0-php8.4-apache","latest"]}\n';;
      *) return 99;;
    esac
  }
  run joomlaRuntimeTags joomla
  assert_success
  assert_output_contains '5.4.0-php8.4-apache'
  local cache
  cache=$(joomlaRuntimeTagCache joomla)
  assert_equal "$(wc -l < "$cache" | tr -d ' ')" 3
  # Native Windows ACLs do not expose the Unix mode requested by chmod.
  if ! is_windows; then assert_equal "$(file_mode "$cache")" 600; fi
  refute_file_contains "$cache" anonymous-repository-token
}

@test "registry pagination never forwards its token to another origin" {
  curl() {
    local headers='' previous='' arg
    for arg in "$@"; do
      [ "$previous" != --dump-header ] || headers="$arg"
      previous="$arg"
    done
    case "${*: -1}" in
      https://auth.docker.io/token\?*) printf '{"access_token":"anonymous-token"}\n';;
      https://registry-1.docker.io/*)
        printf 'Link: <https://untrusted.invalid/tags/list?n=1000>; rel="next"\r\n' > "$headers"
        printf '{"name":"library/joomla","tags":["latest"]}\n';;
      *) touch "$SANDBOX/token-forwarded"; return 99;;
    esac
  }
  run joomlaRuntimeRegistryTags library/joomla
  assert_failure
  refute_file_exists "$SANDBOX/token-forwarded"
}

@test "failed discovery preserves the last complete cache and rejects malformed tags" {
  local cache
  cache=$(joomlaRuntimeTagCache joomla)
  mkdir -p "${cache%/*}"
  printf 'previous-complete-tag\n' > "$cache"
  curl() {
    local headers='' previous='' arg
    for arg in "$@"; do
      [ "$previous" != --dump-header ] || headers="$arg"
      previous="$arg"
    done
    case "${*: -1}" in
      https://hub.docker.com/*) return 22;;
      https://auth.docker.io/*) printf '{"token":"anonymous-token"}\n';;
      https://registry-1.docker.io/*)
        : > "$headers"
        printf '{"name":"library/joomla","tags":["valid","invalid\\nforged-tag"]}\n';;
      *) return 99;;
    esac
  }
  run joomlaRuntimeTags joomla
  assert_failure
  assert_equal "$(cat "$cache")" previous-complete-tag
  [ -z "$(find "${cache%/*}" -name '*.tmp.*' -print)" ]
}

@test "successful Hub discovery uses only actual catalog names" {
  curl() {
    case "${*: -1}" in
      https://hub.docker.com/*) printf '{"results":[{"name":"actual-tag"}],"next":null}\n';;
      *) touch "$SANDBOX/unneeded-fallback"; return 99;;
    esac
  }
  run joomlaRuntimeTags docker.io/joomla
  assert_success
  assert_equal "$output" actual-tag
  refute_file_exists "$SANDBOX/unneeded-fallback"
}

@test "native PHP reader distinguishes CLI timeout overrides from ordered web startup configuration" {
  command -v php >/dev/null || skip 'native PHP CLI is unavailable; Docker acceptance covers web values'
  local scan="$SANDBOX/php-scan" main="$SANDBOX/main.ini" reader
  mkdir -p "$scan"
  printf 'max_execution_time = 60\nmax_input_time = 90\n' > "$main"
  printf 'max_execution_time = 180\nmemory_limit = 512M\n[PATH=/private]\nmax_execution_time = 999\n' > "$scan/10-runtime.ini"
  printf '[Date]\nmax_input_time = 240\n[HOST=private.test]\nmax_input_time = 888\n' > "$scan/20-runtime.ini"
  reader=$(joomlaPHPConfigurationReader)
  run env PHP_INI_SCAN_DIR="$scan" php -c "$main" -r "$reader"'
    echo get_cfg_var("max_execution_time"), ",", get_cfg_var("max_input_time"), "\n";
    echo octojoomConfiguredPHPValue("max_execution_time"), ",", octojoomConfiguredPHPValue("max_input_time"), ",", octojoomConfiguredPHPValue("memory_limit");'
  assert_success
  assert_equal "$output" $'0,-1\n180,240,512M'
}

@test "native staged validation accepts requested timeouts but rejects a later INI override" {
  command -v php >/dev/null || skip 'native PHP CLI is unavailable; Docker acceptance covers web values'
  local native_php native_staged scan="$SANDBOX/php-scan" main="$SANDBOX/main.ini" staged
  native_php=$(command -v php)
  mkdir -p "$scan"
  : > "$main"
  staged="$scan/10-octojoom.ini"
  printf 'max_execution_time = 180\nmax_input_time = 240\nmemory_limit = 512M\n' > "$staged"
  # Use the host SAPI's exact scanned path for the transport stand-in. Native
  # Windows PHP reports backslashes/drive letters while Bash uses POSIX paths;
  # production validation runs entirely inside the Linux container namespace.
  native_staged=$(env PHP_INI_SCAN_DIR="$scan" "$native_php" -c "$main" -r '
    foreach (preg_split("/,\\s*/", trim((string) php_ini_scanned_files()), -1, PREG_SPLIT_NO_EMPTY) as $file) {
      if (basename($file) === "10-octojoom.ini") { echo $file; exit(0); }
    }
    exit(1);')
  [ -n "$native_staged" ]
  # Replace only Docker's transport/mount mapping; execute the production PHP
  # validation program with a real PHP SAPI and real loaded configuration.
  docker() {
    while [ "$1" != -r ]; do shift; done
    local code="$2"
    shift 4
    env PHP_INI_SCAN_DIR="$scan" "$native_php" -c "$main" -r "$code" -- "$native_staged" "$@"
  }
  run joomlaPHPValidateIni test/php "$staged" /php/conf.d/zz-octojoom.ini max_execution_time 180 max_input_time 240 memory_limit 512M
  assert_success
  printf 'max_execution_time = 45\n' > "$scan/99-vendor.ini"
  run joomlaPHPValidateIni test/php "$staged" /php/conf.d/zz-octojoom.ini max_execution_time 180
  assert_failure
  assert_output_contains 'PHP did not accept the proposed max_execution_time setting.'
  printf 'memory_limit = "unterminated\n' > "$scan/99-vendor.ini"
  run joomlaPHPValidateIni test/php "$staged" /php/conf.d/zz-octojoom.ini max_execution_time 180
  assert_failure
  assert_output_contains 'A loaded PHP configuration file could not be parsed.'
}

php_settings_fixture() {
  PHP_TEST_STAGE="$SANDBOX/php-stage"
  VDM_SITE_DIR="$VDM_REPO_PATH/joomla/available/example.test"
  VDM_SITE_COMPOSE="$VDM_SITE_DIR/docker-compose.yml"
  VDM_SITE_ENV="$VDM_SITE_DIR/.env"
  VDM_SITE_KEY=example
  VDM_SITE_ENV_KEY=EXAMPLE
  VDM_SITE_SERVICE=web
  VDM_SITE_IMAGE=custom/php:current
  VDM_SITE_IMAGE_DIGEST=''
  VDM_SITE_RUNNING=stopped
  PHP_TEST_SOURCE="$VDM_PROJECT_PATH/example/php.ini"
  mkdir -p "$PHP_TEST_STAGE" "$VDM_SITE_DIR" "${PHP_TEST_SOURCE%/*}"
  printf 'VDM_PROJECT_PATH="%s"\n' "$VDM_PROJECT_PATH" > "$VDM_SITE_ENV"
  cp "$VDM_SITE_ENV" "$PHP_TEST_STAGE/.env"
  cat > "$PHP_TEST_SOURCE" <<'INI'
max_execution_time = "120"
max_input_time = 1500
max_input_vars = 3000
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
upload_max_filesize = 256M
post_max_size = 256M
memory_limit = "256M"
date.timezone = Africa/Windhoek
INI
  printf 'max_input_time = 1500   \n' >> "$PHP_TEST_SOURCE"
  printf 'services:\n  web:\n    image: custom/php:current\n    volumes:\n      - "%s:/usr/local/etc/php/conf.d/zz-octojoom.ini:ro"\n' "$PHP_TEST_SOURCE" > "$VDM_SITE_COMPOSE"
  joomlaRuntimeIniTarget() { printf '/usr/local/etc/php/conf.d/zz-octojoom.ini\n'; }
  joomlaPHPValidateIni() { return 0; }
  joomlaSiteCompose() {
    if [ "$2" = config ]; then
      joomlaSiteJSON -cn --arg source "$PHP_TEST_SOURCE" '{services:{web:{volumes:[{type:"bind",source:$source,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini"}]}}}'
    else return 99; fi
  }
}

@test "interactive PHP questions accept single digits and retry invalid answers" {
  OCTOJOOM_NON_INTERACTIVE=false
  answers 0 invalid 1
  run joomlaPHPQuestion max_execution_time 124
  assert_success
  assert_equal "$output" 0
  run joomlaPHPQuestion max_input_vars 3000
  assert_success
  assert_equal "$output" 1
  assert_answers_used
  assert_equal "$(grep -c '^--inputbox' "$STUB_DIR/dialogs.log")" 3
}

@test "INI defaults accept quoted values and whitespace through all seven questions" {
  php_settings_fixture
  OCTOJOOM_NON_INTERACTIVE=false
  getInput() { printf '%s\n' "$3" >> "$SANDBOX/questions"; printf '%s\n' "$2"; }
  run joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/questions" | tr -d ' ')" 7
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'max_execution_time = 120'
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'max_input_time = 1500'
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'memory_limit = 256M'
  assert_file_contains "$PHP_TEST_STAGE/docker-compose.yml" "$(joomlaWebHostPath "$PHP_TEST_SOURCE"):/usr/local/etc/php/conf.d/zz-octojoom.ini:ro"
  assert_file_contains "$PHP_TEST_SOURCE" 'max_execution_time = "120"'
  refute_file_exists "$VDM_SITE_DIR/php.ini"
}

@test "cancelling a later PHP question publishes nothing and retains the original" {
  php_settings_fixture
  OCTOJOOM_NON_INTERACTIVE=false
  answers 300 '<esc>'
  run joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_status 255
  assert_answers_used
  refute_file_exists "$PHP_TEST_STAGE/php.ini"
  refute_file_exists "$PHP_TEST_STAGE/docker-compose.yml"
  assert_file_contains "$PHP_TEST_SOURCE" 'max_execution_time = "120"'
}

@test "existing site-owned PHP files remain the published destination" {
  php_settings_fixture
  OCTOJOOM_TEST_REQUEST=VDM_max_execution_time
  VDM_max_execution_time=300
  joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_equal "$OCTOJOOM_SITE_PHP_FILE" "$PHP_TEST_SOURCE"
  assert_equal "${OCTOJOOM_SITE_FILE_TARGETS[0]}" "$PHP_TEST_SOURCE"
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'max_execution_time = 300'
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'date.timezone = Africa/Windhoek'
  assert_file_contains "$VDM_SRC_PATH/.env" "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\""
  refute_file_exists "$VDM_SITE_DIR/php.ini"
}

@test "earlier staging relocation retains saved values while restoring the project path" {
  php_settings_fixture
  printf 'max_execution_time = 124\n' > "$PHP_TEST_SOURCE"
  PHP_TEST_SOURCE="$VDM_SITE_DIR/php.ini"
  printf 'max_execution_time = 300\nmemory_limit = 512M\ndate.timezone = Africa/Windhoek\n' > "$PHP_TEST_SOURCE"
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  VDM_memory_limit=768M
  joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_equal "$OCTOJOOM_SITE_PHP_FILE" "$VDM_PROJECT_PATH/example/php.ini"
  assert_equal "$OCTOJOOM_PHP_OLD_FILE" "$VDM_SITE_DIR/php.ini"
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'max_execution_time = 300'
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'memory_limit = 768M'
  assert_file_contains "$VDM_PROJECT_PATH/example/php.ini" 'max_execution_time = 124'
  assert_file_contains "$VDM_SITE_DIR/php.ini" 'max_execution_time = 300'
}

@test "an INI consumed by another site is isolated without changing the shared source" {
  php_settings_fixture
  PHP_TEST_SOURCE="$SANDBOX/company.ini"
  printf 'memory_limit = 128M\n' > "$PHP_TEST_SOURCE"
  mkdir -p "$VDM_REPO_PATH/joomla/available/second.test"
  cp "$VDM_SITE_COMPOSE" "$VDM_REPO_PATH/joomla/available/second.test/docker-compose.yml"
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  VDM_memory_limit=512M
  joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_equal "$OCTOJOOM_SITE_PHP_FILE" "$VDM_PROJECT_PATH/example/php.ini"
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'memory_limit = 512M'
  assert_file_contains "$PHP_TEST_SOURCE" 'memory_limit = 128M'
}

@test "restoring an earlier staging path never overwrites another site's destination INI" {
  php_settings_fixture
  PHP_TEST_SOURCE="$VDM_SITE_DIR/php.ini"
  printf 'max_execution_time = 300\n' > "$PHP_TEST_SOURCE"
  mkdir -p "$VDM_REPO_PATH/joomla/available/second.test"
  cp "$VDM_SITE_COMPOSE" "$VDM_REPO_PATH/joomla/available/second.test/docker-compose.yml"
  joomlaSiteCompose() {
    local bind="$PHP_TEST_SOURCE"
    [ "$1" != second.test ] || bind="$VDM_PROJECT_PATH/example/php.ini"
    joomlaSiteJSON -cn --arg source "$bind" '{services:{web:{volumes:[{type:"bind",source:$source,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini"}]}}}'
  }
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  VDM_memory_limit=512M
  run joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_failure
  assert_output_contains 'destination PHP file is used by another website'
  refute_file_exists "$PHP_TEST_STAGE/php.ini"
  assert_file_contains "$PHP_TEST_SOURCE" 'max_execution_time = 300'
  assert_file_contains "$VDM_PROJECT_PATH/example/php.ini" 'max_execution_time = "120"'
}

@test "an unrelated disabled site's missing database variables do not block PHP edits" {
  php_settings_fixture
  local other="$VDM_REPO_PATH/joomla/available/second.test"
  mkdir -p "$other"
  printf 'VDM_PROJECT_PATH="%s"\n' "$VDM_PROJECT_PATH" > "$other/.env"
  cat > "$other/docker-compose.yml" <<'YAML'
services:
  second:
    environment:
      - JOOMLA_DB_PASSWORD=${VDM_SECOND_DB_PASS:?missing}
    volumes:
      - "${VDM_PROJECT_PATH}/second/php.ini:/php.ini:ro"
YAML
  joomlaSiteCompose() {
    [ "$1" != second.test ] || return 1
    joomlaSiteJSON -cn --arg source "$PHP_TEST_SOURCE" '{services:{web:{volumes:[{type:"bind",source:$source,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini"}]}}}'
  }
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  VDM_memory_limit=512M
  run joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_success
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'memory_limit = 512M'
  assert_file_contains "$PHP_TEST_STAGE/docker-compose.yml" "$(joomlaWebHostPath "$PHP_TEST_SOURCE"):/usr/local/etc/php/conf.d/zz-octojoom.ini:ro"
  # A broken service is still a real consumer when its known mount is shared.
  sed -i.bak 's@/second/php.ini@/example/php.ini@' "$other/docker-compose.yml"
  run joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_failure
  assert_output_contains 'also used by another website'
  assert_file_contains "$PHP_TEST_SOURCE" 'memory_limit = "256M"'
}

@test "a partial first PHP edit also writes every global default" {
  php_settings_fixture
  printf 'VDM_max_execution_time=222\nVDM_max_input_vars=7000\n' >> "$VDM_SRC_PATH/.env"
  joomlaSiteCompose() { printf '{"services":{"web":{"volumes":[]}}}\n'; }
  printf 'services:\n  web:\n    volumes:\n      - "website:/var/www/html"\n' > "$VDM_SITE_COMPOSE"
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  VDM_memory_limit=512M
  run joomlaPHPSettingsAction example.test "$PHP_TEST_STAGE"
  assert_success
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'max_execution_time = 222'
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'max_input_vars = 7000'
  assert_file_contains "$PHP_TEST_STAGE/php.ini" 'memory_limit = 512M'
  assert_equal "$(grep -c ' = ' "$PHP_TEST_STAGE/php.ini")" 7
}

@test "PHP project paths use the selected site's saved base and persistent folder" {
  php_settings_fixture
  printf 'VDM_PROJECT_PATH="%s/old-projects"\n' "$SANDBOX" > "$VDM_SITE_ENV"
  VDM_SITE_MOUNT_TYPE=bind
  VDM_SITE_MOUNT_SOURCE="$SANDBOX/old-projects/renamed-project/joomla"
  run joomlaPHPProjectIni example.test
  assert_success
  assert_equal "$output" "$SANDBOX/old-projects/renamed-project/php.ini"
}

@test "Windows native backslashes do not break detection of a shared PHP source" {
  OS_NUMBER=3
  VDM_SITE_SERVICE=web
  cygpath() { local path="${*: -1}"; printf '/c/%s\n' "${path:3}"; }
  local model
  model='{"services":{"web":{"volumes":[]},"sibling":{"volumes":[{"type":"bind","source":"C:\\Users\\dev\\php.ini","target":"/php.ini"}]}}}'
  run joomlaPHPIniShared example.test /c/Users/dev/php.ini "$model"
  assert_success
}

@test "PHP apply validation is independent of local HTTPS and database availability" {
  VDM_max_execution_time=300
  OCTOJOOM_EXPECTED_PHP=8.4.1
  OCTOJOOM_PHP_CHANGED_SETTINGS='max_execution_time '
  readJoomlaSiteFacts() { VDM_SITE_SERVICE=web; VDM_SITE_URL=https://wrong-certificate.localhost; }
  joomlaSiteCompose() {
    printf '%s\n' "$*" >> "$SANDBOX/validation-calls"
    [[ " $* " == *' --interactive=false '* ]] || return 98
    if [[ "$*" == *'echo PHP_VERSION;'* ]]; then printf '8.4.1'; fi
  }
  joomlaDatabaseVerifyConnection() { touch "$SANDBOX/database-check"; return 99; }
  curl() { touch "$SANDBOX/http-check"; return 60; }
  run joomlaPHPValidatePublished example.test
  assert_success
  refute_file_exists "$SANDBOX/database-check"
  refute_file_exists "$SANDBOX/http-check"
  assert_file_contains "$SANDBOX/validation-calls" 'max_execution_time 300'
}

@test "PHP apply still rejects a mismatched value or a changed PHP version" {
  VDM_memory_limit=512M
  OCTOJOOM_EXPECTED_PHP=8.4.1
  OCTOJOOM_PHP_CHANGED_SETTINGS='memory_limit '
  readJoomlaSiteFacts() { VDM_SITE_SERVICE=web; }
  joomlaSiteCompose() {
    if [[ "$*" == *'echo PHP_VERSION;'* ]]; then printf '8.4.1'; else return 1; fi
  }
  run joomlaPHPValidatePublished example.test
  assert_failure
  assert_output_contains 'PHP did not load the requested memory_limit value.'
  joomlaSiteCompose() { printf '8.5.0'; }
  run joomlaPHPValidatePublished example.test
  assert_failure
  assert_output_contains 'did not load the selected PHP runtime'
}

@test "the PHP handler retains the previous managed file on failure and removes it after publication" {
  php_settings_fixture
  VDM_CONTAINER=example.test
  VDM_ACTION=settings
  PHP_TEST_SOURCE="$VDM_SITE_DIR/php.ini"
  printf 'max_execution_time = 300\nmemory_limit = 256M\n' > "$PHP_TEST_SOURCE"
  OCTOJOOM_TEST_REQUEST=VDM_memory_limit
  VDM_memory_limit=512M
  readJoomlaSiteFacts() { return 0; }
  sitePublishConfiguration() { return 1; }
  run joomla__TRuST__php
  assert_failure
  assert_file_contains "$PHP_TEST_SOURCE" 'max_execution_time = 300'
  assert_file_contains "$VDM_PROJECT_PATH/example/php.ini" 'max_execution_time = "120"'
  sitePublishConfiguration() {
    [ "$OCTOJOOM_SITE_VALIDATE_FUNCTION" = joomlaPHPValidatePublished ] || return 99
    cp "${OCTOJOOM_SITE_FILE_SOURCES[0]}" "${OCTOJOOM_SITE_FILE_TARGETS[0]}" || return 1
    cp "$2" "$VDM_SITE_COMPOSE" || return 1
    cp "$3" "$VDM_SITE_ENV"
  }
  run joomla__TRuST__php
  assert_success
  assert_output_contains 'takes effect when the website starts'
  assert_file_contains "$VDM_PROJECT_PATH/example/php.ini" 'max_execution_time = 300'
  assert_file_contains "$VDM_PROJECT_PATH/example/php.ini" 'memory_limit = 512M'
  refute_file_exists "$PHP_TEST_SOURCE"
}
