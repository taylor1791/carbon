# Tests for `carbon check` -- static validation of the service dependency graph.
#
# check reports errors and warnings separately but exits 1 for either, so every
# test pins both the exit status and the diagnostic.

setup() {
  load helper
  _common_setup
  carbon_repo
}

# The smallest graph that passes every check: one producer, one consumer, and
# no push key left unpulled.
clean_graph() {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
TOML
  service producer <<'TOML'
[push.url]
value = "https://example.com"
TOML
}

@test "check passes on a clean graph" {
  clean_graph
  run ./carbon check
  assert_success
  assert_output --partial "check passed"
}

@test "check passes on a repo with no services" {
  run ./carbon check
  assert_success
  assert_output --partial "check passed"
}

# --- duplicate names --------------------------------------------------------

@test "check reports duplicate service names" {
  clean_graph
  service copycat --name producer <<'TOML'
[push.other]
value = "x"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "duplicate service name"
  assert_output --partial "producer"
}

@test "check lists every path holding a duplicated name" {
  service one --name twin <<'TOML'
[push.a]
value = "1"
TOML
  service two --name twin <<'TOML'
[push.b]
value = "2"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "one/carbon.toml"
  assert_output --partial "two/carbon.toml"
}

# --- missing service --------------------------------------------------------

@test "check reports a pull from a service that does not exist" {
  service consumer <<'TOML'
[pull.url]
service = "ghost-service"
name = "url"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "missing service"
  assert_output --partial "ghost-service"
}

# --- missing push key -------------------------------------------------------

@test "check reports a pull of a key the target does not push" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "no_such_key"
TOML
  service producer <<'TOML'
[push.url]
value = "https://example.com"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "missing push key"
  assert_output --partial "no_such_key"
}

# --- circular dependency ----------------------------------------------------

@test "check reports a two-service cycle" {
  service alpha <<'TOML'
[pull.x]
service = "beta"
name = "x"
[push.x]
value = "1"
TOML
  service beta <<'TOML'
[pull.x]
service = "alpha"
name = "x"
[push.x]
value = "2"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "circular dependency"
  assert_output --partial "alpha"
  assert_output --partial "beta"
}

@test "check reports a three-service cycle" {
  service alpha <<'TOML'
[pull.x]
service = "beta"
name = "x"
[push.x]
value = "1"
TOML
  service beta <<'TOML'
[pull.x]
service = "gamma"
name = "x"
[push.x]
value = "2"
TOML
  service gamma <<'TOML'
[pull.x]
service = "alpha"
name = "x"
[push.x]
value = "3"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "circular dependency"
  assert_output --partial "gamma"
}

@test "check does not treat a self-pull as a cycle" {
  service solo <<'TOML'
[push.password]
value = "p"
expect_unused = true
[pull.password]
service = "solo"
TOML
  run ./carbon check
  assert_success
  refute_output --partial "circular dependency"
}

# --- unused push key --------------------------------------------------------

@test "check warns about a push key nobody pulls" {
  service lonely <<'TOML'
[push.orphan_key]
value = "unused"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "unused push key"
  assert_output --partial "orphan_key"
}

@test "check counts an unused push key as a warning, not an error" {
  service lonely <<'TOML'
[push.orphan_key]
value = "unused"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "1 warnings"
  refute_output --partial "errors"
}

@test "expect_unused suppresses the unused push key warning" {
  service lonely <<'TOML'
[push.orphan_key]
value = "unused"
expect_unused = true
TOML
  run ./carbon check
  assert_success
  refute_output --partial "unused push key"
}

@test "check warns when an expect_unused key is pulled after all" {
  service producer <<'TOML'
[push.some_key]
value = "val"
expect_unused = true
TOML
  service consumer <<'TOML'
[pull.x]
service = "producer"
name = "some_key"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "expected unused push key is pulled"
  assert_output --partial "some_key"
}

@test "a self-pulled key still needs expect_unused" {
  service solo <<'TOML'
[push.password]
value = "p"
[pull.password]
service = "solo"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "unused push key"
}

# --- derive checks ----------------------------------------------------------

@test "check passes a derive that references a real pull" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[derive.full_url]
value = "https://{{pull.url}}/api"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_success
}

@test "check reports a derive that collides with a pull name" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[derive.url]
value = "https://{{pull.url}}/api"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "derive/pull name collision"
  assert_output --partial "url"
}

@test "check reports a derive referencing a pull that does not exist" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[derive.full_url]
value = "https://{{pull.nope}}/api"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "invalid derive reference"
  assert_output --partial "nope"
}

@test "check passes an array-form derive with valid references" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[[derive.full_url]]
registry_pattern = "dev"
value = "https://{{pull.url}}/dev"
[[derive.full_url]]
value = "https://{{pull.url}}/default"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_success
}

@test "check inspects every entry of an array-form derive" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[[derive.full_url]]
registry_pattern = "dev"
value = "https://{{pull.url}}/dev"
[[derive.full_url]]
value = "https://{{pull.nope}}/default"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "invalid derive reference"
  assert_output --partial "nope"
}

# --- name case collisions ---------------------------------------------------

@test "check reports a derive that differs from a pull only by case" {
  service consumer <<'TOML'
[pull.aws_access_key_id]
service = "producer"
name = "aws_access_key_id"
[derive.AWS_ACCESS_KEY_ID]
value = "{{pull.aws_access_key_id}}"
TOML
  service producer <<'TOML'
[push.aws_access_key_id]
value = "AKIA"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "name case collision"
  assert_output --partial "aws_access_key_id"
  assert_output --partial "AWS_ACCESS_KEY_ID"
}

@test "check names the spelling that survives the collision" {
  service consumer <<'TOML'
[pull.token]
service = "producer"
name = "token"
[derive.TOKEN]
value = "{{pull.token}}"
TOML
  service producer <<'TOML'
[push.token]
value = "t"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial 'one variable named "token"'
}

@test "check reports two pulls that differ only by case" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[pull.URL]
service = "producer"
name = "url"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "name case collision"
}

@test "check passes names that differ by more than case" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[derive.URL_BASE]
value = "https://{{pull.url}}"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_success
}

# An identically named pull and derive is a different mistake, already reported
# by its own check. Reporting it twice would send the reader looking for a
# casing difference that is not there.
@test "check does not report an exact derive/pull collision as a case collision" {
  service consumer <<'TOML'
[pull.url]
service = "producer"
name = "url"
[derive.url]
value = "https://{{pull.url}}/api"
TOML
  service producer <<'TOML'
[push.url]
value = "example.com"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "derive/pull name collision"
  refute_output --partial "name case collision"
}


# --- env references in push -------------------------------------------------

@test "check reports {{env}} in a push value" {
  service svc <<'TOML'
[push.api_key]
value = "{{env.MY_SECRET}}"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "env reference in push"
  assert_output --partial "MY_SECRET"
}

@test "check reports {{env}} in a push command" {
  service svc <<'TOML'
[push.api_key]
command = "echo {{env.MY_SECRET}}"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "env reference in push"
  assert_output --partial "MY_SECRET"
}

@test "check reports {{env}} in an array-form push" {
  service svc <<'TOML'
[[push.api_key]]
registry_pattern = "dev"
value = "static"
[[push.api_key]]
value = "{{env.PROD_SECRET}}"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "PROD_SECRET"
}

@test "check allows {{env}} in a derive" {
  service svc <<'TOML'
[derive.api_key]
value = "{{env.MY_SECRET}}"
TOML
  run ./carbon check
  assert_success
  refute_output --partial "env reference in push"
}

# --- summary ----------------------------------------------------------------

@test "check summarises the error count" {
  service consumer <<'TOML'
[pull.a]
service = "ghost-one"
name = "a"
[pull.b]
service = "ghost-two"
name = "b"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "2 errors"
}

@test "check reports errors and warnings together" {
  service consumer <<'TOML'
[pull.a]
service = "ghost-one"
name = "a"
TOML
  service lonely <<'TOML'
[push.orphan]
value = "x"
TOML
  run ./carbon check
  assert_failure
  assert_output --partial "1 errors"
  assert_output --partial "1 warnings"
}
