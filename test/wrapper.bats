# Tests for the nix-packaged wrapper.
#
# The wrapper execs nushell from bash, so every argument crosses a shell
# boundary and arrives as a string. Rest parameters have to collect them
# without any parsing. Sourcing carbon directly passes real nu values and
# would miss this path entirely, which is why these run the built binary.
#
# Skipped unless CARBON_TEST_WRAPPER=1, since building costs a nix evaluation.

setup_file() {
  if [ "${CARBON_TEST_WRAPPER:-}" != "1" ]; then
    return 0
  fi
  CARBON_WRAPPER="$(nix build "${BATS_TEST_DIRNAME}/..#carbon" --no-link --print-out-paths)/bin/carbon"
  export CARBON_WRAPPER
}

setup() {
  load helper
  if [ "${CARBON_TEST_WRAPPER:-}" != "1" ]; then
    skip "set CARBON_TEST_WRAPPER=1 to test the packaged wrapper"
  fi
  CARBON_BIN="$CARBON_WRAPPER"
  _common_setup
}

@test "wrapper initialises a repo" {
  bare_repo
  run ./carbon init
  assert_success
  assert_file_exist .carbon/registry.yaml
}

@test "wrapper scaffolds several services from positional arguments" {
  bare_repo
  ./carbon init svc-a svc-b
  assert_file_exist svc-a/carbon.toml
  assert_file_exist svc-b/carbon.toml
}

@test "wrapper requests several registries from positional arguments" {
  carbon_repo
  ./carbon request wrap1 wrap2
  assert_file_exist .carbon/registry.wrap1.yaml
  assert_file_exist .carbon/registry.wrap2.yaml
  assert_file_exist .carbon/sops.wrap1.yaml
  assert_file_exist .carbon/sops.wrap2.yaml
}

@test "wrapper rekeys several registries from positional arguments" {
  carbon_repo
  ./carbon request wrap1 wrap2
  run ./carbon rekey wrap1 wrap2
  assert_success
}

@test "wrapper supports the bootstrap flow a setup script uses" {
  bare_repo
  ./carbon init
  ./carbon request wrap3
  assert_file_exist .carbon/registry.wrap3.yaml
}

@test "wrapper rejects the retired --registries flag" {
  bare_repo
  run ./carbon init -r "[wrap9]"
  assert_failure
  assert_file_not_exist .carbon/registry.wrap9.yaml
}

@test "wrapper round-trips a pushed value" {
  carbon_repo
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc
  assert_registry svc url "https://example.com"
}

@test "wrapper runs a command without nushell on the caller's PATH" {
  carbon_repo
  service svc <<'TOML'
[derive.greeting]
value = "hello"
TOML
  run env PATH="$(path_without nu)" ./carbon run -s svc -c "printenv greeting"
  assert_success
  assert_output "hello"
}

@test "wrapper reads a value without git on the caller's PATH" {
  carbon_repo
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push svc
  run env PATH="$(path_without git)" ./carbon read svc url
  assert_success
  assert_output "https://example.com"
}

@test "wrapper reads a service named like a nushell literal" {
  carbon_repo
  service inf <<'TOML'
[push.greeting]
value = "hello"
TOML
  ./carbon push inf
  run ./carbon read inf greeting
  assert_success
  assert_output "hello"
}
