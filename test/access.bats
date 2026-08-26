# Tests for request / rekey / view / read -- registry creation and the access
# control that gates decryption.

setup() {
  load helper
  _common_setup
}

# --- request ----------------------------------------------------------------

@test "request creates a named registry and its sops config" {
  carbon_repo
  run ./carbon request dev
  assert_success
  assert_file_exist .carbon/registry.dev.yaml
  assert_file_exist .carbon/sops.dev.yaml
}

@test "request creates several named registries in one call" {
  carbon_repo
  ./carbon request dev stg prd
  assert_file_exist .carbon/registry.dev.yaml
  assert_file_exist .carbon/registry.stg.yaml
  assert_file_exist .carbon/registry.prd.yaml
}

@test "request leaves the default registry untouched" {
  carbon_repo
  ./carbon request dev
  assert_file_exist .carbon/registry.yaml
  assert_registry _carbon version "0.0.3"
}

@test "request adds a second user as a recipient" {
  carbon_repo alice
  as_user bob 2>/dev/null || true
  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  run bash -c "nu -c 'open .carbon/sops.yaml | get users | length'"
  assert_output "2"
}

@test "request twice does not duplicate the user's key" {
  carbon_repo alice
  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  USER=bob ./carbon request
  run bash -c "nu -c 'open .carbon/sops.yaml | get users | length'"
  assert_output "2"
  run bash -c "nu -c 'open .carbon/sops.yaml | get creation_rules.0.age | split row \",\" | length'"
  assert_output "2"
}

@test "request adds the key as a recipient of the creation rule" {
  carbon_repo alice
  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  run bash -c "nu -c 'open .carbon/sops.yaml | get creation_rules.0.age | split row \",\" | length'"
  assert_output "2"
}

# --- read / view ------------------------------------------------------------

@test "read decrypts a single value" {
  carbon_repo
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc
  run ./carbon read svc url
  assert_success
  assert_output "https://example.com"
}

@test "read fails for a key that was never pushed" {
  carbon_repo
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc
  run ./carbon read svc nonexistent
  assert_failure
}

@test "read targets a named registry with -r" {
  carbon_repo
  ./carbon request dev
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[push.url]
value = "https://{{carbon.registry}}.example.com"
TOML
  (cd svc && ../carbon use dev && ../carbon push)
  assert_registry svc url "https://dev.example.com" dev
}

@test "view decrypts the whole registry" {
  carbon_repo
  service svc <<'TOML'
[push.url]
value = "https://example.com"
[push.token]
value = "t0ken"
TOML
  ./carbon push svc
  cd svc
  run ../carbon view
  assert_success
  assert_output --partial "https://example.com"
  assert_output --partial "t0ken"
}

@test "view targets a named registry with -r" {
  carbon_repo
  ./carbon request dev
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[push.token]
value = "dev-only-token"
TOML
  (cd svc && ../carbon use dev && ../carbon push)
  run ./carbon view -r dev
  assert_success
  assert_output --partial "dev-only-token"
}

@test "view reports the carbon version stored at init" {
  carbon_repo
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  cd svc
  run ../carbon view
  assert_success
  assert_output --partial "0.0.3"
}

# --- rekey ------------------------------------------------------------------

@test "a requested but un-rekeyed user cannot decrypt" {
  carbon_repo alice
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc

  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  mv .carbon/private-key.age .carbon/private-key.age.bob

  as_user bob
  run ./carbon read svc url
  assert_failure
}

@test "rekey grants a requested user the ability to decrypt" {
  carbon_repo alice
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc

  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  mv .carbon/private-key.age .carbon/private-key.age.bob

  as_user alice
  ./carbon rekey

  as_user bob
  run ./carbon read svc url
  assert_success
  assert_output "https://example.com"
}

@test "rekey does not rotate the data key when only adding users" {
  carbon_repo alice
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc
  local before
  before="$(nu -c 'open .carbon/registry.yaml | get svc.url')"

  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  mv .carbon/private-key.age .carbon/private-key.age.bob
  as_user alice
  ./carbon rekey

  local after
  after="$(nu -c 'open .carbon/registry.yaml | get svc.url')"
  assert_equal "$before" "$after"
}

@test "rekey rotates the data key when a user is removed" {
  carbon_repo alice
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc

  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  mv .carbon/private-key.age .carbon/private-key.age.bob
  as_user alice
  ./carbon rekey

  local before
  before="$(nu -c 'open .carbon/registry.yaml | get svc.url')"

  # Drop bob back out of the creation rule and re-key.
  nu -c 'let first = (open .carbon/sops.yaml | get creation_rules.0.age | split row "," | first)
         open .carbon/sops.yaml | update creation_rules [{age: $first}] | save -f .carbon/sops.yaml'
  ./carbon rekey

  local after
  after="$(nu -c 'open .carbon/registry.yaml | get svc.url')"
  refute [ "$before" = "$after" ]
}

@test "a removed user can no longer decrypt" {
  carbon_repo alice
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc

  rm -f .carbon/private-key.age
  USER=bob ./carbon request
  mv .carbon/private-key.age .carbon/private-key.age.bob
  as_user alice
  ./carbon rekey

  as_user bob
  run ./carbon read svc url
  assert_success

  as_user alice
  nu -c 'let first = (open .carbon/sops.yaml | get creation_rules.0.age | split row "," | first)
         open .carbon/sops.yaml | update creation_rules [{age: $first}] | save -f .carbon/sops.yaml'
  ./carbon rekey

  as_user bob
  run ./carbon read svc url
  assert_failure
}

@test "rekey accepts several named registries" {
  carbon_repo alice
  ./carbon request dev prd
  rm -f .carbon/private-key.age
  USER=bob ./carbon request dev prd
  mv .carbon/private-key.age .carbon/private-key.age.bob

  as_user alice
  run ./carbon rekey dev prd
  assert_success

  as_user bob
  run ./carbon read -r dev _carbon version
  assert_success
  assert_output "0.0.3"
}
