#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034
load ../helpers/common

setup() {
  octojoom_setup
  work="$SANDBOX/healthcheck"
  mkdir "$work"
  cp "$HELPERS_DIR/playground-legacy-healthcheck.json" "$work/healthcheck.json"
}

write_healthcheck_site() {
  joomlaSiteJSON '{services:{app:{healthcheck:.}}}' < "$work/healthcheck.json" > "$work/original-model.json"
  cat > "$work/with-env.yml" <<'YAML'
services:
  app:
    image: joomla:latest
    # Keep the selected service and its other settings unchanged.
    restart: unless-stopped
YAML
  printf '    healthcheck: %s\n' "$(joomlaSiteJSON -c 'walk(if type=="string" then gsub("\\$"; "$$") else . end)' < "$work/healthcheck.json")" >> "$work/with-env.yml"
  cat >> "$work/with-env.yml" <<'YAML'
    labels:
      - "traefik.enable=true"
  other:
    image: nginx:alpine
    healthcheck:
      test: ["CMD", "custom-neighbor-check"]
YAML
  cp "$work/with-env.yml" "$work/before.yml"
}

@test "replacement restores the exact original readable Apache healthcheck from the rejected probe" {
  write_healthcheck_site
  joomlaPlaygroundRestoreApacheHealthcheck "$work" app
  local expected
  expected=$(cat <<'YAML'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 5
YAML
  )
  assert_equal "$(joomlaServiceProperty "$work/with-env.yml" app healthcheck)" "$expected"
  assert_equal "$(joomlaServiceProperty "$work/with-env.yml" app labels)" "$(joomlaServiceProperty "$work/before.yml" app labels)"
  assert_equal "$(joomlaServiceBlock "$work/with-env.yml" other)" "$(joomlaServiceBlock "$work/before.yml" other)"
  assert_file_contains "$work/with-env.yml" '# Keep the selected service and its other settings unchanged.'
  refute_file_contains "$work/with-env.yml" 'set-cookie:'
}

@test "restoring the known probe retains custom timings and disabled state with a nested document root" {
  joomlaSiteJSON '.test[5]="/var/www/html/store/public" | .interval="45s" | .timeout="12s" |
    .retries=9 | .start_period="50s" | .start_interval="2s" | .disable=true' < "$work/healthcheck.json" > "$work/revised.json"
  mv "$work/revised.json" "$work/healthcheck.json"
  write_healthcheck_site
  joomlaPlaygroundRestoreApacheHealthcheck "$work" app
  assert_file_contains "$work/with-env.yml" '      interval: 45s'
  assert_file_contains "$work/with-env.yml" '      timeout: 12s'
  assert_file_contains "$work/with-env.yml" '      retries: 9'
  assert_file_contains "$work/with-env.yml" '      start_period: 50s'
  assert_file_contains "$work/with-env.yml" '      start_interval: 2s'
  assert_file_contains "$work/with-env.yml" '      disable: true'
}

@test "replacement leaves stock, absent, disabled and custom healthchecks byte-for-byte unchanged" {
  local healthcheck
  for healthcheck in \
    '{"test":["CMD","curl","-f","http://localhost/"],"interval":"30s","timeout":"5s","retries":5}' \
    '{"test":["CMD-SHELL","curl -fsS http://127.0.0.1/custom"],"interval":"10s"}' \
    '{"disable":true}' 'null'; do
    printf '%s\n' "$healthcheck" > "$work/healthcheck.json"
    write_healthcheck_site
    joomlaPlaygroundRestoreApacheHealthcheck "$work" app
    cmp -s "$work/before.yml" "$work/with-env.yml"
  done
}

@test "replacement never rewrites a customized variant of the rejected probe" {
  local filter
  cp "$work/healthcheck.json" "$work/legacy.json"
  for filter in '.test[3]+="\n# operator customization"' '.test[6]="custom.example.test"' '.test[7]="nginx"'; do
    joomlaSiteJSON "$filter" < "$work/legacy.json" > "$work/healthcheck.json"
    write_healthcheck_site
    joomlaPlaygroundRestoreApacheHealthcheck "$work" app
    cmp -s "$work/before.yml" "$work/with-env.yml"
  done
}

@test "restoring the known healthcheck is idempotent and handles actual Compose dollar serialization" {
  [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" compose version >/dev/null 2>&1 || skip 'Docker Compose is unavailable'
  write_healthcheck_site
  "$REAL_DOCKER" compose --project-name healthcheck --file "$work/with-env.yml" config --format json > "$work/rendered.json"
  joomlaSiteJSON 'walk(if type=="string" then gsub("\\$\\$"; "$") else . end)' < "$work/rendered.json" > "$work/original-model.json"
  joomlaPlaygroundRestoreApacheHealthcheck "$work" app
  "$REAL_DOCKER" compose --project-name healthcheck --file "$work/with-env.yml" config --format json > "$work/original-model.json"
  joomlaSiteJSON -e '.services.app.healthcheck=={test:["CMD","curl","-f","http://localhost/"],interval:"30s",timeout:"5s",retries:5}' < "$work/original-model.json"
  cp "$work/with-env.yml" "$work/restored.yml"
  joomlaPlaygroundRestoreApacheHealthcheck "$work" app
  cmp -s "$work/restored.yml" "$work/with-env.yml"
}
