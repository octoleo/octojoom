#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  work="$SANDBOX/work"
  mkdir -p "$work" "$SANDBOX/web" "$SANDBOX/db"
  web=$(joomlaWebHostPath "$SANDBOX/web")
  db=$(joomlaWebHostPath "$SANDBOX/db")
  printf '{"app":"php","db":"mysql"}\n' > "$work/services.json"
  joomlaSiteJSON -n --arg web "$web" --arg db "$db" '{
    services:{php:{volumes:[{type:"bind",source:$web,target:"/var/www/html"}]},
              nginx:{volumes:[{type:"bind",source:$web,target:"/var/www/html",read_only:true}]},
              mysql:{volumes:[{type:"bind",source:$db,target:"/var/lib/mysql"}]}}}' > "$work/original-model.json"
  joomlaSiteJSON -n --arg web "$web" '[{Type:"bind",Source:$web,Destination:"/var/www/html",RW:true}]' > "$work/actual.json"
  joomlaSiteCompose() {
    [ "$1 $2 $3" = 'fixture ps -aq' ] || return 1
    case "$4" in php) echo selected-php;; mysql) return 0;; *) return 1;; esac
  }
  docker() {
    [ "$1" = inspect ] && [ "${!#}" = selected-php ] || return 1
    cat "$work/actual.json"
  }
}

edit_json() {
  local file="$1"
  shift
  joomlaSiteJSON "$@" < "$file" > "$work/changed.json" && mv "$work/changed.json" "$file"
}

@test "selected storage accepts an exact Nginx consumer and a matching legacy PHP mount" {
  local ini
  ini=$(joomlaWebHostPath "$SANDBOX/php.ini")
  : > "$SANDBOX/php.ini"
  edit_json "$work/original-model.json" --arg ini "$ini" '.services.php.volumes += [{type:"bind",source:$ini,target:"/var/www/html/php.ini"}]'
  edit_json "$work/actual.json" --arg ini "$ini" '. += [{Type:"bind",Source:$ini,Destination:"/var/www/html/php.ini",RW:true}]'
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_success
  edit_json "$work/actual.json" '.[1].Source += ".different"'
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_failure
  assert_output_contains 'different or unsupported mounts'
}

@test "selected storage rejects a read-only actual root and an actual mount masked by the Compose model" {
  edit_json "$work/actual.json" '.[0].RW=false'
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_failure
  assert_output_contains 'different or unsupported mounts'
  edit_json "$work/actual.json" '.[0].RW=true | . += [{Type:"volume",Name:"assets",Destination:"/var/www/html/assets"}]'
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_failure
  assert_output_contains 'different or unsupported mounts'
}

@test "replacement rejects the input ZIP and prospective PHP configuration inside the selected store" {
  local archive="$SANDBOX/web/site.zip"
  : > "$archive"
  run joomlaPlaygroundReplacementStorage fixture "$work" "$archive"
  assert_failure
  assert_output_contains 'overlaps its import inputs or deployment configuration'
  cd -- "$SANDBOX"
  run joomlaPlaygroundReplacementStorage fixture "$work" web/site.zip
  assert_failure
  assert_output_contains 'overlaps its import inputs or deployment configuration'
  printf '%s\n' "$SANDBOX/web/php.ini" > "$work/ini-destination.path"
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_failure
  assert_output_contains 'overlaps its import inputs or deployment configuration'
}

@test "replacement resolves an input alias and checks host-side companion mount overlap" {
  if ! is_windows; then
    ln -s "$SANDBOX/web" "$SANDBOX/package-dir"
    ln -s "$SANDBOX/web/export.zip" "$SANDBOX/archive-alias.zip"
    : > "$SANDBOX/web/export.zip"
    cd -- "$SANDBOX"
    run joomlaPlaygroundReplacementStorage fixture "$work" archive-alias.zip
    assert_failure
    assert_output_contains 'overlaps its import inputs or deployment configuration'
    run joomlaPlaygroundReplacementStorage fixture "$work" "$SANDBOX/package-dir/export.zip"
    assert_failure
    assert_output_contains 'overlaps its import inputs or deployment configuration'
  fi
  edit_json "$work/original-model.json" --arg web "$web" '.services.nginx.volumes += [
    {type:"bind",source:($web+"/nginx.conf"),target:"/etc/nginx/conf.d/default.conf"}]'
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_failure
  assert_output_contains 'Another mount in the selected Compose project'
}

@test "a bind in the selected project cannot alias the physical backing path of its website volume" {
  edit_json "$work/original-model.json" '
    .volumes.website={name:"selected_web"} |
    (.services.php.volumes[0],.services.nginx.volumes[0]) |= (.type="volume"|.source="website") |
    .services.nginx.volumes += [{type:"bind",source:"/var/lib/docker/volumes/selected_web/_data/config",target:"/etc/nginx/conf.d"}]'
  edit_json "$work/actual.json" '.[0] |= (.Type="volume"|.Name="selected_web")'
  docker() {
    case "$1 $2" in
      'volume inspect')
        [ "$3" = selected_web ] || return 1
        echo '[{"Driver":"local","Mountpoint":"/var/lib/docker/volumes/selected_web/_data"}]';;
      'inspect --format')
        [ "${!#}" = selected-php ] || return 1
        cat "$work/actual.json";;
      *) return 1;;
    esac
  }
  run joomlaPlaygroundReplacementStorage fixture "$work"
  assert_failure
  assert_output_contains 'Another mount in the selected Compose project'
}
