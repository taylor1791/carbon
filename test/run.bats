# Tests for `carbon run` -- executing a command with the service's resolved
# configuration in the environment.

setup() {
  load helper
  _common_setup
  carbon_repo
}

producer() {
  service producer <<'TOML'
[push.gateway]
value = "https://example.com"
TOML
  ./carbon push producer
}

@test "run exposes pulled values as environment variables" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  run ./carbon run -s consumer -c "printenv base_url"
  assert_success
  assert_output "https://example.com"
}

@test "run exposes derived values as environment variables" {
  producer
  service consumer <<'TOML'
[pull.db_host]
service = "producer"
name = "gateway"
[derive.database_url]
value = "postgres://app@{{pull.db_host}}/mydb"
TOML
  run ./carbon run -s consumer -c "printenv database_url"
  assert_success
  assert_output "postgres://app@https://example.com/mydb"
}

@test "run exits zero when the command succeeds" {
  service svc <<'TOML'
[pull]
TOML
  run ./carbon run -s svc -c "exit 0"
  assert_success
}

@test "run propagates a non-zero exit code" {
  service svc <<'TOML'
[pull]
TOML
  run ./carbon run -s svc -c "exit 3"
  assert_equal "$status" 3
}

@test "run propagates a failing external command's exit code" {
  service svc <<'TOML'
[pull]
TOML
  run ./carbon run -s svc -c "^false"
  assert_failure
}

@test "run does not resolve configuration into the parent environment" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  ./carbon run -s consumer -c "printenv base_url" >/dev/null
  run printenv base_url
  assert_failure
}

@test "run finds the closest ancestor service when given no --service" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  mkdir -p consumer/src
  cd consumer/src
  run ../../carbon run -c "printenv base_url"
  assert_success
  assert_output "https://example.com"
}

@test "run fails when a pulled dependency cannot be resolved" {
  producer
  service consumer <<'TOML'
[pull.missing]
service = "producer"
name = "never_published"
TOML
  run ./carbon run -s consumer -c "echo should not get here"
  assert_failure
  refute_output --partial "should not get here"
}
