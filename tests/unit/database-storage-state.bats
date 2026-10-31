#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  mkdir -p "$SANDBOX/data/db" "$SANDBOX/data/db-other"
  storage_fixture true false "$SANDBOX/data/db"
}

storage_fixture() {
  jq -n --argjson running "$1" --argjson restarting "$2" --arg source "$3" \
    '[{State:{Running:$running,Restarting:$restarting},Mounts:[{Type:"bind",Source:$source}]}]' > "$SANDBOX/inspect.json"
}

docker() {
  case "$1" in
    ps) printf 'database-id\n' ;;
    inspect) printf 'inspect\n' >> "$SANDBOX/inspections"; cat "$SANDBOX/inspect.json" ;;
    *) return 99 ;;
  esac
}

@test "database publication ignores a container stopped between ps and inspect" {
  storage_fixture false false "$SANDBOX/data/db"
  run joomlaDatabaseStorageStopped "$SANDBOX/data/db"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/inspections" | tr -d ' ')" 1
}

@test "database publication rechecks a settling mount before allowing directory moves" {
  probe_storage() {
    sleep() { storage_fixture false false "$SANDBOX/data/db"; }
    joomlaDatabaseStorageStopped "$SANDBOX/data/db"
  }
  run probe_storage
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/inspections" | tr -d ' ')" 2
}

@test "a persistent live mount is refused after bounded observation without stopping any container" {
  probe_storage() {
    sleep() { :; }
    joomlaDatabaseStorageStopped "$SANDBOX/data/db"
  }
  run probe_storage
  assert_failure
  assert_output_contains 'Database storage is still mounted'
  assert_output_contains "$SANDBOX/data/db"
  assert_equal "$(wc -l < "$SANDBOX/inspections" | tr -d ' ')" 10
}

@test "restarting containers still prevent database directory publication" {
  storage_fixture false true "$SANDBOX/data/db"
  probe_storage() {
    sleep() { :; }
    joomlaDatabaseStorageStopped "$SANDBOX/data/db"
  }
  run probe_storage
  assert_failure
  assert_output_contains 'Database storage is still mounted'
}

@test "live parent and child bind mounts remain protected" {
  local source
  for source in "$SANDBOX/data" "$SANDBOX/data/db/subdirectory"; do
    storage_fixture true false "$source"
    probe_storage() {
      sleep() { :; }
      joomlaDatabaseStorageStopped "$SANDBOX/data/db"
    }
    run probe_storage
    assert_failure
    assert_output_contains 'Database storage is still mounted'
  done
}

@test "similarly named sibling data directories are not treated as shared storage" {
  storage_fixture true false "$SANDBOX/data/db-other"
  run joomlaDatabaseStorageStopped "$SANDBOX/data/db"
  assert_success
}

@test "missing state and invalid inspect output fail closed" {
  local fixture
  for fixture in '' 'null' '[]' '[{"Mounts":[]}]' '[{"State":{"Running":false,"Restarting":false}}]'; do
    printf '%s\n' "$fixture" > "$SANDBOX/inspect.json"
    run joomlaDatabaseStorageStopped "$SANDBOX/data/db"
    assert_failure
  done
}

@test "Docker inspection errors never permit directory publication" {
  probe_storage() {
    docker() { if [ "$1" = ps ]; then printf 'database-id\n'; else return 27; fi; }
    joomlaDatabaseStorageStopped "$SANDBOX/data/db"
  }
  run probe_storage
  assert_failure
}
