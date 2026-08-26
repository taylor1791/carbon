# Tests for `carbon init` -- key bootstrap, gitignore management, and service
# scaffolding.

setup() {
  load helper
  _common_setup
}

@test "init creates the user's private key" {
  bare_repo
  run ./carbon init
  assert_success
  assert_file_exist .carbon/private-key.age
}

@test "init creates the default registry and sops config" {
  bare_repo
  ./carbon init
  assert_file_exist .carbon/registry.yaml
  assert_file_exist .carbon/sops.yaml
}

@test "init adds the private key to .gitignore" {
  bare_repo
  ./carbon init
  assert_file_contains .gitignore '^/\.carbon/private-key\.age$'
}

@test "init creates .gitignore when the repo has none" {
  git init -q -b main .
  install_carbon
  git add -A
  git -c user.email=t@e -c user.name=t commit -qm fixture
  rm -f .gitignore
  ./carbon init
  assert_file_exist .gitignore
  assert_file_contains .gitignore 'private-key\.age'
}

@test "init preserves existing .gitignore entries" {
  bare_repo
  printf '/result\n/node_modules\n' > .gitignore
  ./carbon init
  assert_file_contains .gitignore '^/result$'
  assert_file_contains .gitignore '^/node_modules$'
  assert_file_contains .gitignore 'private-key\.age'
}

@test "init does not duplicate the gitignore entry when run twice" {
  bare_repo
  ./carbon init
  ./carbon init
  run grep -c 'private-key\.age' .gitignore
  assert_output "1"
}

@test "init records the carbon version in the registry" {
  carbon_repo
  assert_registry _carbon version "0.0.3"
}

@test "init registers exactly one user in the sops config" {
  carbon_repo
  run bash -c "nu -c 'open .carbon/sops.yaml | get users | length'"
  assert_output "1"
}

@test "init records the user's name from \$USER" {
  bare_repo
  USER=zelda ./carbon init
  run bash -c "nu -c 'open .carbon/sops.yaml | get users.0.name'"
  assert_output "zelda"
}

@test "init scaffolds a carbon.toml for a named service" {
  bare_repo
  ./carbon init svc-a
  assert_file_exist svc-a/carbon.toml
  assert_file_contains svc-a/carbon.toml 'name = "svc-a"'
}

@test "init scaffolds several services in one call" {
  bare_repo
  ./carbon init svc-a svc-b svc-c
  assert_file_exist svc-a/carbon.toml
  assert_file_exist svc-b/carbon.toml
  assert_file_exist svc-c/carbon.toml
}

@test "init creates nested service directories" {
  bare_repo
  ./carbon init services/api/auth
  assert_file_exist services/api/auth/carbon.toml
}

@test "init does not overwrite an existing carbon.toml" {
  bare_repo
  service svc-a <<'TOML'
[push.url]
value = "do not clobber me"
TOML
  ./carbon init svc-a
  assert_file_contains svc-a/carbon.toml 'do not clobber me'
}

@test "init with no services still bootstraps the registry" {
  bare_repo
  run ./carbon init
  assert_success
  assert_file_exist .carbon/registry.yaml
}

@test "init by a second user does not disturb the first user's access" {
  carbon_repo alice
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc

  # A second developer clones and bootstraps. Their key is requested but not
  # yet granted, and alice must still be able to read.
  rm -f .carbon/private-key.age
  USER=bob ./carbon init
  mv .carbon/private-key.age .carbon/private-key.age.bob
  as_user alice
  assert_registry svc url "https://example.com"
}

@test "the retired --registries flag is rejected rather than ignored" {
  bare_repo
  run ./carbon init -r '[dev]'
  assert_failure
  assert_file_not_exist .carbon/registry.dev.yaml
}
