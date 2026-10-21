#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317,SC2016
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
  printf 'memory_limit = 128M\ndate.timezone = UTC\n' > "$SANDBOX/shared.ini"
  printf 'services:\n  web:\n    volumes:\n      - "%s:/var/www/html/php.ini"\n' "$SANDBOX/shared.ini" > "$VDM_SITE_COMPOSE"
  : > "$stage/.env"
  joomlaRuntimeIniTarget() { echo /php/conf.d/zz-octojoom.ini; }
  joomlaSiteCompose() { printf '{"services":{"web":{"volumes":[{"type":"bind","source":"%s/shared.ini","target":"/var/www/html/php.ini"}]}}}\n' "$SANDBOX"; }
  run joomlaPHPSettingsAction "$site" "$stage"
  assert_success
  assert_file_contains "$VDM_SRC_PATH/.env" 'VDM_memory_limit="128M"'
  assert_file_contains "$SANDBOX/shared.ini" 'memory_limit = 128M'
  assert_file_contains "$stage/php.ini" 'memory_limit = 512M'
  assert_file_contains "$stage/php.ini" 'date.timezone = UTC'
  assert_file_contains "$stage/.env" 'VDM_EXAMPLE_PHP_MEMORY_LIMIT=512M'
  assert_file_contains "$stage/docker-compose.yml" "$VDM_SITE_DIR/php.ini:/php/conf.d/zz-octojoom.ini:ro"
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
  local stage="$SANDBOX/stage" shared="$SANDBOX/shared.ini"
  mkdir -p "$stage" "$SANDBOX/site"
  VDM_SITE_DIR="$SANDBOX/site"
  VDM_SITE_SERVICE=web
  printf 'memory_limit = 512M\ndate.timezone = Africa/Windhoek\n' > "$shared"
  printf 'services:\n  web:\n    image: custom/php:new\n    volumes:\n      - "%s:/var/www/html/php.ini"\n' "$shared" > "$stage/docker-compose.yml"
  joomlaSiteCompose() { printf '{"services":{"web":{"volumes":[{"type":"bind","source":"%s/shared.ini","target":"/var/www/html/php.ini"}]}}}\n' "$SANDBOX"; }
  joomlaRuntimeIniTarget() { echo /new/php/conf.d/zz-octojoom.ini; }
  joomlaPHPValidateIni() { return 0; }
  run joomlaPHPStageExistingOverrides example.test "$stage" custom/php:new
  assert_success
  assert_file_contains "$stage/docker-compose.yml" 'image: custom/php:new'
  assert_file_contains "$stage/docker-compose.yml" "$VDM_SITE_DIR/php.ini:/new/php/conf.d/zz-octojoom.ini:ro"
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
