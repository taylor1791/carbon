#!/usr/bin/env nu

use std/assert

rm -rf .carbon
rm -rf .gitignore
assert not (".carbon/private-key.age" | path exists)

# Test the init command
USER=user1 ./carbon init .carbon/service-1
assert (".gitignore" | path exists)
assert (open .gitignore | str contains "/.carbon/private-key.age")
assert (".carbon/private-key.age" | path exists)
assert (1 == (open .carbon/sops.yaml | get users | length))
assert (".carbon/registry.yaml" | path exists)
assert (".carbon/service-1/carbon.toml" | path exists)
assert ((./carbon read _carbon version | str trim) == "0.0.2")
mv .carbon/private-key.age .carbon/private-key.age.user1

# Test the init command with a registry
USER=user2 ./carbon init .carbon/service-2 --registries '[dev,prd]'
assert ("./.carbon/registry.dev.yaml" | path exists)
assert ("./.carbon/registry.prd.yaml" | path exists)
assert ("./.carbon/sops.dev.yaml" | path exists)
assert ("./.carbon/sops.prd.yaml" | path exists)
assert (".carbon/service-2/carbon.toml" | path exists)
mv .carbon/private-key.age .carbon/private-key.age.user2

# Create a service that depends on another service
USER=user3 ./carbon init .carbon/service-3
assert (".carbon/service-3/carbon.toml" | path exists)
mv .carbon/private-key.age .carbon/private-key.age.user3

# Test the push command with values
as_user "user1"
{
  name: "service-without-dependencies"
  push: {
    gateway: {
      value: "https://example.com"
    }
  }
} | save -f .carbon/service-1/carbon.toml
./carbon push .carbon/service-1
open .carbon/registry.yaml | get service-without-dependencies.gateway

# Test the pull command and push with commands
as_user "user1"
{
  name: "service-with-dependencies"
  pull: {
    base_url: {
      service: "service-without-dependencies"
      name: "gateway"
    }
  }
  push: {
    password: {
      command: "echo 'P@ssw0rd'"
    }
  }
} | save -f .carbon/service-3/carbon.toml
./carbon pull .carbon/service-3
open .carbon/service-3/.environment.json | get base_url
./carbon push .carbon/service-3
open .carbon/registry.yaml | get service-with-dependencies.password

# Test registries using the push, pull, and use commands.
as_user "user2"
do {
  cd .carbon/service-2

  {
    name: "service-with-registry"
    file: "secrets.json"
    registry: {
      use: {
        command: "echo {{carbon.registry}} > REGISTRY"
      }
      current: {
        command: "cat REGISTRY"
      }
    }
    pull: {
      password: {
        service: "service-with-registry"
        default: {
          command: "cat /dev/random | tr -dc 'A-Za-z0-9' | head -c 20"
        }
      }
    }
    push: {
      password: [{
        shell: "nu -c"
        command: "open secrets.json | get 'password'"
      }]
      queue_url: {
        value: "http://localhost/{{carbon.registry}}-jobs"
      }
    }
  } | save -f carbon.toml

  ../../carbon use dev
  assert ("dev" == (open REGISTRY | str trim))
  ../../carbon pull
  open secrets.json | get password
  ../../carbon push
  open ../registry.dev.yaml | get service-with-registry.password
  assert ("http://localhost/dev-jobs" == (../../carbon read -r dev service-with-registry queue_url))
}

# Test the derive section in pull
as_user "user1"
{
  name: "service-with-derive"
  pull: {
    db_host: {
      service: "service-without-dependencies"
      name: "gateway"
    }
  }
  push: {
    gateway: {
      value: "https://example.com"
    }
  }
  derive: {
    database_url: {
      value: "postgres://app:secret@{{pull.db_host}}/mydb"
    }
  }
} | save -f .carbon/service-1/carbon.toml
./carbon push .carbon/service-1
./carbon pull .carbon/service-1
let derive_env = open .carbon/service-1/.environment.json
assert (($derive_env | get database_url) == "postgres://app:secret@https://example.com/mydb") "derive should compose pull values"
assert (($derive_env | get db_host) == "https://example.com") "pull values should still be present"

# Test adding a user
as_user "user3"
let initial_password = open .carbon/registry.yaml | get service-with-dependencies.password
./carbon request
let sops = open .carbon/sops.yaml
assert (($sops | get users | length) == 2)
assert (($sops | get creation_rules.0.age | split row "," | length) == 2)

# Adding users does not rotate the key
as_user "user1"
./carbon rekey
let password_after_add = open .carbon/registry.yaml | get service-with-dependencies.password
assert ($initial_password == $password_after_add)

# Test removing a user
let user = open .carbon/sops.yaml | get creation_rules.0.age | split row "," | first
open .carbon/sops.yaml | update creation_rules [{age: $user}] | save -f .carbon/sops.yaml

./carbon rekey
let password_after_remove = open .carbon/registry.yaml | get service-with-dependencies.password
assert ($initial_password != $password_after_remove)

def as_user [
  name: string
] {
  cp $".carbon/private-key.age.($name)" .carbon/private-key.age
}

# Test the check command - passes with aligned services
{ name: "svc-a", pull: { url: { service: "svc-b", name: "url" } }, push: {} } | save -f .carbon/service-1/carbon.toml
{ name: "svc-b", pull: {}, push: { url: { value: "https://example.com" } } } | save -f .carbon/service-2/carbon.toml
{ name: "svc-c", pull: {}, push: {} } | save -f .carbon/service-3/carbon.toml
let check_pass = (./carbon check | complete)
assert ($check_pass.exit_code == 0) "check should pass with unique service names"
let check_pass_output = $"($check_pass.stdout)($check_pass.stderr)"
assert ($check_pass_output | str contains "check passed") "should report check passed"

# Test the check command - detects duplicate service names
mkdir .carbon/service-4
{
  name: "svc-a"
  pull: {}
  push: {}
} | save -f .carbon/service-4/carbon.toml

let check_dup = (./carbon check | complete)
assert ($check_dup.exit_code == 1) "check should fail with duplicate service names"
let check_dup_output = $"($check_dup.stdout)($check_dup.stderr)"
assert ($check_dup_output | str contains "duplicate service name") "should report duplicate"
assert ($check_dup_output | str contains "svc-a") "should name the duplicate service"
rm -rf .carbon/service-4

# Test the check command - detects missing service
{
  name: "service-missing-dep"
  pull: {
    base_url: {
      service: "nonexistent-service"
      name: "gateway"
    }
  }
  push: {}
} | save -f .carbon/service-3/carbon.toml

let check_missing = (./carbon check | complete)
assert ($check_missing.exit_code == 1) "check should fail with missing service"
let check_missing_output = $"($check_missing.stdout)($check_missing.stderr)"
assert ($check_missing_output | str contains "missing service") "should report missing service"
assert ($check_missing_output | str contains "nonexistent-service") "should name the missing service"

# Test the check command - detects missing push key
{
  name: "service-missing-key"
  pull: {
    db_url: {
      service: "svc-a"
      name: "no_such_key"
    }
  }
  push: {}
} | save -f .carbon/service-3/carbon.toml

let check_key = (./carbon check | complete)
assert ($check_key.exit_code == 1) "check should fail with missing push key"
let check_key_output = $"($check_key.stdout)($check_key.stderr)"
assert ($check_key_output | str contains "missing push key") "should report missing push key"
assert ($check_key_output | str contains "no_such_key") "should name the missing key"

# Test the check command - detects circular dependency
{
  name: "cycle-a"
  pull: {
    x: { service: "cycle-b", name: "x" }
  }
  push: { x: { value: "1" } }
} | save -f .carbon/service-1/carbon.toml

{
  name: "cycle-b"
  pull: {
    x: { service: "cycle-a", name: "x" }
  }
  push: { x: { value: "2" } }
} | save -f .carbon/service-3/carbon.toml

let check_cycle = (./carbon check | complete)
assert ($check_cycle.exit_code == 1) "check should fail with circular dependency"
let check_cycle_output = $"($check_cycle.stdout)($check_cycle.stderr)"
assert ($check_cycle_output | str contains "circular dependency") "should report circular dependency"
assert ($check_cycle_output | str contains "cycle-a") "should name service in cycle"
assert ($check_cycle_output | str contains "cycle-b") "should name other service in cycle"

# Test the check command - detects unused push key
{
  name: "svc-unused"
  pull: {}
  push: { orphan_key: { value: "unused" } }
} | save -f .carbon/service-1/carbon.toml

{
  name: "svc-other"
  pull: {}
  push: {}
} | save -f .carbon/service-3/carbon.toml

let check_unused = (./carbon check | complete)
assert ($check_unused.exit_code == 1) "unused push key should fail"
let check_unused_output = $"($check_unused.stdout)($check_unused.stderr)"
assert ($check_unused_output | str contains "unused push key") "should report unused push key"
assert ($check_unused_output | str contains "orphan_key") "should name the unused key"

# Test the check command - expect_unused suppresses unused push key warning
{
  name: "svc-unused"
  pull: {}
  push: { orphan_key: { value: "unused", expect_unused: true } }
} | save -f .carbon/service-1/carbon.toml

{ name: "svc-clean", pull: {}, push: {} } | save -f .carbon/service-2/carbon.toml

{
  name: "svc-other"
  pull: {}
  push: {}
} | save -f .carbon/service-3/carbon.toml

let check_expect_unused = (./carbon check | complete)
assert ($check_expect_unused.exit_code == 0) "expect_unused should suppress unused push key warning"
let check_expect_unused_output = $"($check_expect_unused.stdout)($check_expect_unused.stderr)"
assert (not ($check_expect_unused_output | str contains "unused push key")) "should not report unused push key"

# Test the check command - expect_unused on a pulled key warns
{
  name: "svc-expect-unused-pulled"
  pull: {}
  push: { some_key: { value: "val", expect_unused: true } }
} | save -f .carbon/service-1/carbon.toml

{
  name: "svc-puller"
  pull: { x: { service: "svc-expect-unused-pulled", name: "some_key" } }
  push: {}
} | save -f .carbon/service-3/carbon.toml

let check_eu_pulled = (./carbon check | complete)
assert ($check_eu_pulled.exit_code == 1) "expect_unused on pulled key should warn"
let check_eu_pulled_output = $"($check_eu_pulled.stdout)($check_eu_pulled.stderr)"
assert ($check_eu_pulled_output | str contains "expected unused push key is pulled") "should report expected unused but pulled"
assert ($check_eu_pulled_output | str contains "some_key") "should name the key"

# Test the graph command
{ name: "auth-service", pull: { db_url: { service: "db-service", name: "db_url" }, password: { service: "db-service", name: "password" } }, push: { api_key: { value: "key" }, jwt_secret: { value: "secret" } } } | save -f .carbon/service-1/carbon.toml
{ name: "db-service", pull: {}, push: { db_url: { value: "postgres://localhost" }, password: { value: "secret" } } } | save -f .carbon/service-2/carbon.toml
{ name: "cache-service", pull: {}, push: {} } | save -f .carbon/service-3/carbon.toml

let graph = (./carbon graph | complete)
assert ($graph.exit_code == 0) "graph should succeed"
let graph_output = $graph.stdout
assert ($graph_output | str contains "digraph") "should contain digraph"
assert ($graph_output | str contains "rankdir=LR") "should contain rankdir"
assert ($graph_output | str contains "auth-service") "should contain auth-service node"
assert ($graph_output | str contains "db-service") "should contain db-service node"
assert ($graph_output | str contains "cache-service") "should contain cache-service node"
assert ($graph_output | str contains 'auth-service" -> "db-service"') "should contain edge from auth to db"
assert ($graph_output | str contains "db_url") "should label edge with pulled secret"

# Test the check command - passes with valid derive
{ name: "svc-a", pull: { url: { service: "svc-b", name: "url" } }, push: {}, derive: { full_url: { value: "https://{{pull.url}}/api" } } } | save -f .carbon/service-1/carbon.toml
{ name: "svc-b", pull: {}, push: { url: { value: "example.com" } } } | save -f .carbon/service-2/carbon.toml
{ name: "svc-c", pull: {}, push: {} } | save -f .carbon/service-3/carbon.toml

let check_derive_pass = (./carbon check | complete)
assert ($check_derive_pass.exit_code == 0) "check should pass with valid derive"

# Test the check command - detects derive/pull name collision
{ name: "svc-a", pull: { url: { service: "svc-b", name: "url" } }, push: {}, derive: { url: { value: "https://{{pull.url}}/api" } } } | save -f .carbon/service-1/carbon.toml

let check_collision = (./carbon check | complete)
assert ($check_collision.exit_code == 1) "check should fail with derive/pull collision"
let check_collision_output = $"($check_collision.stdout)($check_collision.stderr)"
assert ($check_collision_output | str contains "derive/pull name collision") "should report collision"
assert ($check_collision_output | str contains "url") "should name the colliding key"
