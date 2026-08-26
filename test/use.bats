# Tests for `carbon use` -- switching which registry a service reads and writes.

setup() {
  load helper
  _common_setup
  carbon_repo
}

# A service that records its current registry in a file.
switchable() {
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[push.host]
value = "host-{{carbon.registry}}"
[pull.host]
service = "svc"
TOML
}

@test "use runs the service's registry.use command" {
  ./carbon request dev
  switchable
  (cd svc && ../carbon use dev)
  assert_equal "$(cat svc/REGISTRY)" "dev"
}

@test "use accepts a service path instead of a working directory" {
  ./carbon request dev
  switchable
  run ./carbon use dev svc
  assert_success
  assert_equal "$(cat svc/REGISTRY)" "dev"
}

@test "use switches which registry push writes to" {
  ./carbon request dev prd
  switchable
  (cd svc && ../carbon use dev && ../carbon push)
  (cd svc && ../carbon use prd && ../carbon push)
  assert_registry svc host "host-dev" dev
  assert_registry svc host "host-prd" prd
}

@test "use switches which registry pull reads from" {
  ./carbon request dev prd
  switchable
  (cd svc && ../carbon use dev && ../carbon push && ../carbon pull)
  assert_env svc/secrets.json host "host-dev"
  (cd svc && ../carbon use prd && ../carbon push && ../carbon pull)
  assert_env svc/secrets.json host "host-prd"
}

@test "registries are isolated from one another" {
  ./carbon request dev prd
  switchable
  (cd svc && ../carbon use dev && ../carbon push)
  # prd never received a push, so reading from it must fail.
  run ./carbon read -r prd svc host
  assert_failure
}

@test "use fails for a service that declares no registry.use" {
  service plain <<'TOML'
[push.url]
value = "https://example.com"
TOML
  run ./carbon use dev plain
  assert_failure
  assert_message "does not support changing registry"
}

@test "use names the offending service in its error" {
  service plain <<'TOML'
[push.url]
value = "https://example.com"
TOML
  run ./carbon use dev plain
  assert_failure
  assert_message "The service plain"
}
