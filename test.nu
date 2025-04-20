#!/home/taylor1791/src/nushell/target/release/nu

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
mv .carbon/private-key.age .carbon/private-key.age.user1

# Test the init command with a namespace
USER=user2 ./carbon init .carbon/service-2 --namespace '[dev,prd]'
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

# Test namespaces using the push, pull, and use commands.
as_user "user2"
do {
  cd .carbon/service-2

  {
    name: "service-with-namespace"
    file: "secrets.json"
    namespace: {
      use: {
        command: "echo {{namespace}} > NAMESPACE"
      }
      current: {
        command: "cat NAMESPACE"
      }
    }
    pull: {
      password: {
        service: "service-with-namespace"
        default: {
          command: "cat /dev/random | tr -dc 'A-Za-z0-9' | head -c 20"
        }
      }
    }
    push: {
      password: {
        shell: "nu -c"
        command: "open secrets.json | get 'password'"
      }
    }
  } | save -f carbon.toml

  ../../carbon use dev
  assert ("dev" == (open NAMESPACE | str trim))
  ../../carbon pull
  open secrets.json | get password
  ../../carbon push
  open ../registry.dev.yaml | get service-with-namespace.password
}

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
