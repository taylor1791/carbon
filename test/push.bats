# Tests for `carbon push` -- how a service's exposed configuration is resolved
# and written to the registry.
#
# Every assertion decrypts the pushed value with `carbon read` rather than
# checking that a ciphertext key exists.

setup() {
  load helper
  _common_setup
  carbon_repo
}

@test "push stores a literal value" {
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  run ./carbon push svc
  assert_success
  assert_registry svc url "https://example.com"
}

@test "push stores the output of a command" {
  service svc <<'TOML'
[push.password]
command = "echo 'P@ssw0rd'"
TOML
  ./carbon push svc
  assert_registry svc password "P@ssw0rd"
}

@test "push trims trailing whitespace from command output" {
  service svc <<'TOML'
[push.token]
command = "printf '  spaced  \n'"
TOML
  ./carbon push svc
  assert_registry svc token "spaced"
}

@test "push runs commands with an explicit shell" {
  service svc <<'TOML'
[[push.total]]
shell = "nu -c"
command = "[1 2 3] | math sum"
TOML
  ./carbon push svc
  assert_registry svc total "6"
}

@test "push runs commands from the service directory" {
  service svc <<'TOML'
[push.secret]
command = "cat secret.txt"
TOML
  echo "from-the-service-dir" > svc/secret.txt
  ./carbon push svc
  assert_registry svc secret "from-the-service-dir"
}

@test "push stores several keys in one call" {
  service svc <<'TOML'
[push.url]
value = "https://example.com"
[push.token]
value = "t0ken"
[push.region]
value = "us-east-1"
TOML
  ./carbon push svc
  assert_registry svc url "https://example.com"
  assert_registry svc token "t0ken"
  assert_registry svc region "us-east-1"
}

@test "push substitutes {{carbon.registry}} in a value" {
  service svc <<'TOML'
[push.queue_url]
value = "http://localhost/{{carbon.registry}}-jobs"
TOML
  ./carbon push svc
  # The default registry has an empty name.
  assert_registry svc queue_url "http://localhost/-jobs"
}

@test "push substitutes {{carbon.registry}} in a command" {
  ./carbon request dev
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[push.queue_url]
command = "echo http://localhost/{{carbon.registry}}-jobs"
TOML
  (cd svc && ../carbon use dev && ../carbon push)
  assert_registry svc queue_url "http://localhost/dev-jobs" dev
}

@test "push picks the array entry whose registry_pattern matches" {
  ./carbon request dev
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[[push.host]]
registry_pattern = "dev"
value = "dev.internal"
[[push.host]]
value = "prod.example.com"
TOML
  (cd svc && ../carbon use dev && ../carbon push)
  assert_registry svc host "dev.internal" dev
}

@test "push falls back to the array default when no pattern matches" {
  ./carbon request prd
  service svc <<'TOML'
file = "secrets.json"
[registry.use]
command = "echo {{carbon.registry}} > REGISTRY"
[registry.current]
command = "cat REGISTRY"
[[push.host]]
registry_pattern = "^dev$"
value = "dev.internal"
[[push.host]]
value = "prod.example.com"
TOML
  (cd svc && ../carbon use prd && ../carbon push)
  assert_registry svc host "prod.example.com" prd
}

@test "push overwrites a previously pushed value" {
  service svc <<'TOML'
[push.url]
value = "https://old.example.com"
TOML
  ./carbon push svc
  assert_registry svc url "https://old.example.com"

  service svc <<'TOML'
[push.url]
value = "https://new.example.com"
TOML
  ./carbon push svc
  assert_registry svc url "https://new.example.com"
}

@test "push uses the service's declared name, not its directory" {
  service some-dir --name canonical-name <<'TOML'
[push.url]
value = "https://example.com"
TOML
  ./carbon push some-dir
  assert_registry canonical-name url "https://example.com"
}

@test "push finds the closest ancestor service when given no path" {
  service svc <<'TOML'
[push.url]
value = "https://example.com"
TOML
  mkdir -p svc/src/deep
  cd svc/src/deep
  run ../../../carbon push
  assert_success
  cd "$BATS_TEST_TMPDIR"
  assert_registry svc url "https://example.com"
}

@test "push succeeds with no push section" {
  service svc <<'TOML'
[pull]
TOML
  run ./carbon push svc
  assert_success
}

@test "push fails when the service has no carbon.toml" {
  mkdir -p empty
  run ./carbon push empty
  assert_failure
}

@test "push fails when a command produces no output" {
  service svc <<'TOML'
[push.nothing]
command = "true"
TOML
  run ./carbon push svc
  assert_failure
  assert_message "returned no output"
}

@test "push fails when an entry has neither value nor command" {
  service svc <<'TOML'
[push.broken]
nonsense = true
TOML
  run ./carbon push svc
  assert_failure
  assert_message "must contain either a value or a command"
}
