# Tests for `carbon graph` -- the DOT rendering of the service dependency graph.

setup() {
  load helper
  _common_setup
  carbon_repo
}

# auth-service pulls two keys from db-service; cache-service stands alone.
fixture_graph() {
  service auth-service <<'TOML'
[pull.db_url]
service = "db-service"
name = "db_url"
[pull.password]
service = "db-service"
name = "password"
[push.api_key]
value = "key"
[push.jwt_secret]
value = "secret"
TOML
  service db-service <<'TOML'
[push.db_url]
value = "postgres://localhost"
[push.password]
value = "secret"
TOML
  service cache-service <<'TOML'
[pull]
TOML
}

@test "graph succeeds and emits a digraph" {
  fixture_graph
  run ./carbon graph
  assert_success
  assert_output --partial "digraph {"
  assert_output --partial "rankdir=LR"
  assert_output --partial "node [shape=record]"
}

@test "graph emits a node for every service" {
  fixture_graph
  run ./carbon graph
  assert_output --partial '"auth-service"'
  assert_output --partial '"db-service"'
  assert_output --partial '"cache-service"'
}

@test "graph labels a node with its push keys" {
  fixture_graph
  run ./carbon graph
  assert_output --partial '"auth-service" [label="auth-service|api_key|jwt_secret"]'
}

@test "graph labels a service with no push keys by name alone" {
  fixture_graph
  run ./carbon graph
  assert_output --partial '"cache-service" [label="cache-service"]'
}

@test "graph draws an edge for a dependency" {
  fixture_graph
  run ./carbon graph
  assert_output --partial '"auth-service" -> "db-service"'
}

@test "graph labels an edge with the pulled keys" {
  fixture_graph
  run ./carbon graph
  assert_output --partial '"auth-service" -> "db-service" [label="db_url, password"]'
}

@test "graph draws no edge for a service with no dependencies" {
  fixture_graph
  run ./carbon graph
  refute_output --partial '"cache-service" ->'
}

@test "graph omits self-referential edges" {
  service solo <<'TOML'
[push.password]
value = "p"
[pull.password]
service = "solo"
TOML
  run ./carbon graph
  assert_success
  refute_output --partial '"solo" -> "solo"'
}

@test "graph closes the digraph" {
  fixture_graph
  run ./carbon graph
  assert_line --index -1 "}"
}

@test "graph on an empty repo is still valid DOT" {
  run ./carbon graph
  assert_success
  assert_output --partial "digraph {"
  assert_line --index -1 "}"
}
