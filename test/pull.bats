# Tests for `carbon pull` -- resolving a service's dependencies out of the
# registry and computing its derived values.

setup() {
  load helper
  _common_setup
  carbon_repo
}

# Publishes a producer service the pull tests can depend on.
producer() {
  service producer <<'TOML'
[push.gateway]
value = "https://example.com"
[push.token]
value = "t0ken"
TOML
  ./carbon push producer
}

# --- pull -------------------------------------------------------------------

@test "pull writes .environment.json by default" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  run ./carbon pull consumer
  assert_success
  assert_file_exist consumer/.environment.json
  assert_env consumer/.environment.json base_url "https://example.com"
}

@test "pull honours the file attribute" {
  producer
  service consumer <<'TOML'
file = "secrets.json"
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  ./carbon pull consumer
  assert_file_exist consumer/secrets.json
  assert_file_not_exist consumer/.environment.json
  assert_env consumer/secrets.json base_url "https://example.com"
}

@test "pull renames a remote key to a local one" {
  producer
  service consumer <<'TOML'
[pull.upstream_url]
service = "producer"
name = "gateway"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json upstream_url "https://example.com"
}

@test "pull uses the local name when no remote name is given" {
  producer
  service consumer <<'TOML'
[pull.gateway]
service = "producer"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json gateway "https://example.com"
}

@test "pull resolves several keys at once" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
[pull.api_token]
service = "producer"
name = "token"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json base_url "https://example.com"
  assert_env consumer/.environment.json api_token "t0ken"
}

@test "pull falls back to a default when the key is not published" {
  service consumer <<'TOML'
[pull.password]
service = "consumer"
[pull.password.default]
value = "generated-locally"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json password "generated-locally"
}

@test "pull runs a default command when the key is not published" {
  service consumer <<'TOML'
[pull.password]
service = "consumer"
[pull.password.default]
command = "echo from-a-command"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json password "from-a-command"
}

@test "pull prefers the published value over the default" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
[pull.base_url.default]
value = "should-not-be-used"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json base_url "https://example.com"
}

@test "pull fails when the key is unpublished and has no default" {
  producer
  service consumer <<'TOML'
[pull.missing]
service = "producer"
name = "never_published"
TOML
  run ./carbon pull consumer
  assert_failure
  assert_message "has not published"
}

@test "pull overwrites a stale environment file" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  echo '{"base_url":"stale","leftover":"gone"}' > consumer/.environment.json
  ./carbon pull consumer
  assert_env consumer/.environment.json base_url "https://example.com"
  run jq -r 'has("leftover")' consumer/.environment.json
  assert_output "false"
}

@test "pull finds the closest ancestor service when given no path" {
  producer
  service consumer <<'TOML'
[pull.base_url]
service = "producer"
name = "gateway"
TOML
  mkdir -p consumer/src/deep
  cd consumer/src/deep
  run ../../../carbon pull
  assert_success
  assert_env "$BATS_TEST_TMPDIR/consumer/.environment.json" base_url "https://example.com"
}

@test "pull writes an empty object when there is nothing to pull" {
  service consumer <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon pull consumer
  run jq -r 'length' consumer/.environment.json
  assert_output "0"
}

@test "pull reads from the service's current registry" {
  ./carbon request dev
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
  (cd svc && ../carbon use dev && ../carbon push && ../carbon pull)
  assert_env svc/secrets.json host "host-dev"
}

# --- derive -----------------------------------------------------------------

@test "derive composes a pulled value" {
  producer
  service consumer <<'TOML'
[pull.db_host]
service = "producer"
name = "gateway"
[derive.database_url]
value = "postgres://app:secret@{{pull.db_host}}/mydb"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json database_url \
    "postgres://app:secret@https://example.com/mydb"
}

@test "derive leaves the pulled values in place" {
  producer
  service consumer <<'TOML'
[pull.db_host]
service = "producer"
name = "gateway"
[derive.database_url]
value = "postgres://{{pull.db_host}}/mydb"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json db_host "https://example.com"
}

@test "derive composes several pulled values" {
  producer
  service consumer <<'TOML'
[pull.host]
service = "producer"
name = "gateway"
[pull.tok]
service = "producer"
name = "token"
[derive.url]
value = "{{pull.host}}?token={{pull.tok}}"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json url "https://example.com?token=t0ken"
}

@test "derive substitutes an environment variable" {
  service consumer <<'TOML'
[derive.aws_key]
value = "{{env.CARBON_TEST_KEY}}"
TOML
  CARBON_TEST_KEY=env-secret ./carbon pull consumer
  assert_env consumer/.environment.json aws_key "env-secret"
}

@test "derive combines environment and pulled values" {
  producer
  service consumer <<'TOML'
[pull.db_host]
service = "producer"
name = "gateway"
[derive.combined]
value = "{{env.CARBON_TEST_KEY}}@{{pull.db_host}}"
TOML
  CARBON_TEST_KEY=env-secret ./carbon pull consumer
  assert_env consumer/.environment.json combined "env-secret@https://example.com"
}

@test "derive substitutes {{carbon.registry}}" {
  ./carbon request dev
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[derive.bucket]
value = "assets-{{carbon.registry}}"
TOML
  (cd svc && ../carbon use dev && ../carbon pull)
  assert_env svc/secrets.json bucket "assets-dev"
}

@test "derive fails when a referenced environment variable is unset" {
  service consumer <<'TOML'
[derive.aws_key]
value = "{{env.CARBON_TEST_DEFINITELY_UNSET}}"
TOML
  run ./carbon pull consumer
  assert_failure
  assert_message "CARBON_TEST_DEFINITELY_UNSET"
  assert_message "aws_key"
}

@test "derive picks the array entry whose registry_pattern matches" {
  ./carbon request dev
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[push.host]
value = "localhost"
[pull.host]
service = "svc"
[[derive.conn_url]]
registry_pattern = "dev"
value = "http://{{pull.host}}:3000"
[[derive.conn_url]]
value = "http://{{pull.host}}:8080"
TOML
  (cd svc && ../carbon use dev && ../carbon push && ../carbon pull)
  assert_env svc/secrets.json conn_url "http://localhost:3000"
}

@test "derive falls back to the array default when no pattern matches" {
  service consumer <<'TOML'
[[derive.aws_key]]
registry_pattern = "^[cl]"
value = "local-fake"
[[derive.aws_key]]
value = "{{env.CARBON_TEST_KEY}}"
TOML
  CARBON_TEST_KEY=real-key ./carbon pull consumer
  assert_env consumer/.environment.json aws_key "real-key"
}

@test "several derives resolve in one pull" {
  producer
  service consumer <<'TOML'
[pull.host]
service = "producer"
name = "gateway"
[derive.a]
value = "a-{{pull.host}}"
[derive.b]
value = "b-{{pull.host}}"
TOML
  ./carbon pull consumer
  assert_env consumer/.environment.json a "a-https://example.com"
  assert_env consumer/.environment.json b "b-https://example.com"
}

@test "a derive cannot reference another derive" {
  service consumer <<'TOML'
[derive.first]
value = "one"
[derive.second]
value = "{{derive.first}}-two"
TOML
  ./carbon pull consumer
  # Derives resolve against pulls and env only, so the reference is literal.
  assert_env consumer/.environment.json second "{{derive.first}}-two"
}
