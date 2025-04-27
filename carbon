#!/usr/bin/env nu

use std/log

let name = "carbon"
let version = "0.0.1"
let git_root = git rev-parse --show-toplevel
let config_dir_name = $".($name)"
let service_config_name = $"($name).toml"
let relative_private_key = ($config_dir_name | path join "private-key.age")
let private_key_file = ($git_root | path join $relative_private_key)

# Encrypted local configuration for monorepo-based service-oriented architectures.
#
# Services in a monorepo expose configuration to other services and consume
# configuration from other services. When using carbon a service code-ifys this in a
# carbon.toml file. All of the published configuration is encrypted and stored in a
# registry. Registries are stored in the monorepo and use envelope encrypted to allow
# specific users to decrypt a registry. Registries are named and isolated to facilitate
# different environment.
#
# Note: This is a work in progress and should not be used in production. E.g., a
# production ready system would have service-level access controls. This is not
# implemented yet.
def main []: nothing -> nothing {
  help main
}

# Bootstraps registries and initializes services.
#
# Performs the following actions:
#  1. Creates a private key for the user if one does not exist.
#  2. Ensures that private key are ignored by git.
#  3. Creates the specified registries and adds the user's public key to the registry if
#     they do not exist.
#  4. Creates a carbon.toml file for the service if one does not exist.
def "main init" [
  service: string # The path of the service to initialize relative to the git root.
  --registries (-n): list<string> = [""] # Initializes these registries if necessary.
]: nothing -> nothing {
  let service_path = ($git_root | path join $service)

  let ignore = ($git_root | path join .gitignore)
  if not ($ignore | path exists) {
    touch $ignore
  }

  let ignore_content = $"/($relative_private_key)"
  if (not (open $ignore | lines | any {|line| $line == $ignore_content})) {
    log debug $"Appending ($ignore_content) to .gitignore..."
    $"\n($ignore_content)" | save $ignore --append
  }

  main request --registries $registries --only-if-created

  for $r in $registries {
    read_sops_config $r
  }

  if not ($service_path | path exists) {
    log debug "Creating service directory..."
    mkdir $service_path
  }

  let service_config_name = $service_path | path join $service_config_name
  let service_config_path = $git_root | path join $service_config_name
  if not ($service_config_path | path exists) {
    log debug $"Creating ($service_config_name)"
    {
      name: $service
      registry: {
        use: {
          command: "echo {{registry}} >> .carbon-registry"
        }
        current: {
          command: "cat .carbon-registry"
        }
      }
      pull: {
        password: {
          service: $service
          default: {
            command: "cat /dev/random | tr -dc 'A-Za-z0-9' | head -c 20"
          }
        }
      }
      push: {
        password: {
          command: "cat .environment.json | jq -r '.password'"
        }
      }
    } | save $service_config_path
  }
}

# Pushes a service's exposed configuration to the registry.
#
# Reads the service's `push` attribute, encrypts the configuration, and writes it to the
# current registry. Only available to users who have access to the registry.
#
# If no service is provided, the closest ancestor service will be used. Provided
# services are relative to the git root.
def "main push" [
  service?: string # Path to the service that will push its configuration to the registry.
]: nothing -> nothing {
  let working_dir = read_working_dir $service
  let service_config = open ($working_dir | path join $service_config_name)
  let registry = read_registry $service_config $working_dir
  let sops = read_sops_config $registry

  let service_name = $service_config | get name | to json --raw
  let publish = $service_config | get push? | default {}
  for secret_name in ($publish | columns) {
    let expression = find_expression $registry ($publish | get $secret_name) $secret_name
    let secret = resolve $expression $working_dir {} | to json --raw
    log debug $"Publishing secret ($secret_name) with value: ($secret)"

    with-env {
      SOPS_AGE_KEY_FILE: $private_key_file 
    } {
      let set_value = $'[($service_name)][($secret_name | to json --raw)] ($secret)'
      sops --config $sops.config_path --set $set_value -i $sops.registry_path
    }
  }
}

# Pulls a service's configuration from the registry.
#
# Read the service's `pull` attribute, decrypts the configuration from the current
# registry, and writes it to the service's `file` attribute. The `file` attribute
# defaults to `.environment.json` if not specified. Only available to users who have
# access to the registry.
#
# If no service is provided, the closest ancestor service will be used. Provided
# services are relative to the git root.
def "main pull" [
  service?: string # Path to the service that will pull its configuration from the registry.
]: nothing -> nothing {
  let working_dir = read_working_dir $service
  let service_config = open ($working_dir | path join $service_config_name)
  let registry = read_registry $service_config $working_dir
  let sops = read_sops_config $registry

  mut contents = {}
  for local_name in ($service_config | get pull? | default {} | columns) {
    let $definition = $service_config | get pull | get $local_name
    let service_name = $definition | get service? | to json
    let remote_name = $definition | get name? | default $local_name | to json
    let secret = $'[($service_name)][($remote_name)]'

    let value = with-env {
      SOPS_AGE_KEY_FILE: $private_key_file 
    } {
      let result = sops --config $sops.config_path --decrypt --extract $secret $sops.registry_path | complete

      match [$result.exit_code, $result.stderr] {
        [0, _] => $result.stdout,
        [_, $err] if $err =~ "component \\[.*\\] not found" and 'default' in $definition => {
          let variables = {
            registry: $registry
          };

          resolve ($definition | get default) $working_dir $variables
        },
        [_, _] => (error make -u {
          msg: $"The ($service_name) service has not published ($remote_name)"
        }),
      }
    }

    log debug $"Pulled secret ($local_name) with value ($value)"
    $contents = ($contents | upsert $local_name $value)
  }

  let file_name = $service_config | get file? | default ".environment.json"
  let file_path = $working_dir | path join $file_name
  log debug $"Saving pulled secrets to ($file_name)"
  $contents | save -f $file_path
}

# Changes the registry used by a service.
#
# Calls the commands specified in the service's `registry.use` attribute.
#
# If no service is provided, the closest ancestor service will be used. Provided
# services are relative to the git root.
def "main use" [
  registry: string
  service?: string # Path to the service that should use the provided registry.
]: nothing -> nothing {
  let working_dir = read_working_dir $service
  let service_config = open ($working_dir | path join $service_config_name)

  if not ('use' in ($service_config | get registry? | default {})) {
    error make -u {
      msg: $"The service ("FIXME") does not support changing registry."
    }
  }

  let variables = {
    registry: $registry
  }

  execute ($service_config | get registry.use) $working_dir $variables
}

# Request access to a registry.
#
# Adds the user's public key to the registry for the provided registries, but does not
# allow the user to decrypt the registry. The user must be granted access by another
# user who has access to the registry by running the `rekey` command.
def "main request" [
  --registries (-r): list<string> = [""] # The registries of which to request access.
  --only-if-created # Only add the user's key if the config file was created.
]: nothing -> nothing {
  if not ($config_dir_name | path exists) {
    log debug "Creating config directory..."
    mkdir $config_dir_name
  }

  if not ($private_key_file | path exists) {
    log debug "Creating private key..."
    rage-keygen --output $private_key_file
  }

  let public_key = rage-keygen -y $private_key_file
  let name = if 'USER' in $env { $env.USER } else { "Enter your name" }
  for $r in $registries {
    let sops_config_file = ($git_root | config_path "sops.yaml" --registry $r)
    let create_config = not ($sops_config_file | path exists)

    if $create_config {
      log debug $"Creating SOPS config ($sops_config_file)"
      {
        creation_rules: [
          { age: "" }
        ]
        users: []
      } | save $sops_config_file
      true
    }

    if not $only_if_created or $create_config and $only_if_created {
      let sops_config = open $sops_config_file
      let rule_index = $sops_config.creation_rules | enumerate
        | where {|row| 'age' in $row.item } | get 0.index
      let new_recipients = $sops_config.creation_rules | get $rule_index | get age
        | split row -r ",\\s*" | where {|line| $line != "" } | append $public_key
        | str join ",\n"

      let updated_creation_rules = $sops_config.creation_rules
        | update $rule_index {|it| $it | update age $new_recipients }
      let updated_config = $sops_config 
        | upsert creation_rules $updated_creation_rules
        | upsert users ($sops_config.users | append { name: $name, key: $public_key })

      $updated_config | save -f $sops_config_file
    }
  }
}

# Applies pending access changes.
#
# Re-encrypts the registry's encryption key with any new user's public key thereby
# allowing them to decrypt the registry. It also removes any users who no longer
# have access to the registry and then rotates the registry key (only if any users
# were removed). Registries can only be updated by another user who has already been
# granted access.
def "main rekey" [
  --registries (-r): list<string> = [""] # The registries which to rekey.
]: nothing -> nothing {
  for r in $registries {
    let sops = read_sops_config $r

    with-env {
      SOPS_AGE_KEY_FILE: $private_key_file
    } {
      let diff = echo n | sops --config $sops.config_path updatekeys $sops.registry_path
      let additions = $diff | lines | where {|line| $line =~ "^\\+" } | length
      let removals = $diff | lines | where {|line| $line =~ "^\\-" } | length

      log debug $"Adding ($additions) and removing ($removals) users to registry ($sops.registry_path)"
      sops --config $sops.config_path updatekeys --yes $sops.registry_path

      if $removals > 0 {
        log debug $"Rotating registry since ($removals) users were removed."
        sops --config $sops.config_path --rotate -i $sops.registry_path
      }
    }
  }
}

# Views the registry.
#
# Decrypts and prints the registry. Only available to users who have access
# to the registry. Defaults to the registry of the closest ancestor service.
def "main view" [
  --registry (-r): string
]: nothing -> nothing {
  let registry = if $registry == null {
    let working_dir = read_working_dir
    let service_config = open ($working_dir | path join $service_config_name)
    read_registry $service_config $working_dir
  } else {
    $registry
  }

  let sops = read_sops_config $registry
  with-env {
    SOPS_AGE_KEY_FILE: $private_key_file
  } {

    sops --config $sops.config_path --decrypt $sops.registry_path
  }
}

def read_working_dir [
  service?: string
] {
  let start = if $service == null { pwd } else { $git_root | path join $service }
  let config_path = find $service_config_name $start $git_root
  if $config_path == null {
    error make -u {
      msg: $"service ($service_config_name) file not found in ($service)"
    }
  }

  $config_path | path dirname
}

def read_registry [
  service_config: record
  working_dir: path
] {
  let service_registry = $service_config | get registry? | default {}

  if not ('current' in $service_registry) {
    log debug "Using default registry since service has no registry.current."
    return ""
  }

  let value = resolve $service_registry.current $working_dir {}
  log debug $"Using value from registry.current: ($value)"

  return $value
}

def read_sops_config [
  registry: string
] {
  let registry_path = config_path "registry.yaml" --registry $registry
  let sops_config_path = ($git_root | config_path "sops.yaml" --registry $registry)
  if not ($registry_path | path exists) {
    log debug $"Creating registry file ($registry_path)"
    { $"_($name)": { version: $version } } | save $registry_path
    sops --config $sops_config_path --encrypt -i $registry_path
  }

  { registry_path: $registry_path config_path: $sops_config_path }
}

def find_expression [
  registry: string
  expressions
  name: string
] {
  let is_array = ($expressions | describe | str starts-with "table") or ($expressions | describe | str starts-with "list")
  let expressions = if $is_array { $expressions } else { [$expressions] }

  let matched = $expressions
    | where {|expression| 'registry_pattern' in $expression }
    | where {|expression| $registry =~ ($expression | get registry_pattern) }
  let defaults = $expressions | where {|expression| not ('registry_pattern' in $expression) }

  match ($matched | length) {
    0 => (match ($defaults | length) {
      0 => (error make -u {
        msg: $"No matching registry patterns for attribute ($name) in registry ($registry)."
      }),
      1 => ($defaults | first),
      _ => (error make -u {
        msg: $"Multiple default patterns for attribute ($name) in registry ($registry)."
      })
    }),
    1 => ($matched | first),
    _ => (error make -u {
      msg: "$Multiple matching registry patterns for attribute ($name) in registry ($registry)."
    })
  }
}

def resolve [
  record: record
  working_dir: path
  variables: record
] {
  if 'value' in $record {
    return $record.value
  }

  if 'command' in $record {
    return (run $record $working_dir $variables)
  }

  error make -u {
    msg: $"The record must contain either a value or a command."
    node: $record
  }
}

def run [
  exec: record<
    command: string
  >
  working_dir: path
  variables: record
] {
  let output = execute $exec $working_dir $variables

  if $output == "" or $output == null {
    error make -u {
      msg: "Command ($command) returned no output."
    }
  }

  return $output
}

def execute [
  exec: record<
    command: string
  >
  working_dir: path
  variables: record
] {
  let shell = $exec | get shell? | default "sh -c"
  let template_command = $exec.command

  let command = $variables | columns | reduce -f $template_command {|key, command|
    $command | str replace --all $"{{($key)}}" ($variables | get $key | into string)
  }
  log debug $"Executing command `($command)` with shell ($shell) from ($working_dir)..."
  let shell_parts = $shell | split row " "
  let output = do -i {
    cd $working_dir
    ^$shell_parts.0 ...($shell_parts | skip 1) $"($command)" | str trim
  }

  return $output
}

def config_path [
  filename: string
  --registry: string = ""
] {
  let file = $filename | path parse

  let suffix = if $registry != "" {
    $".($registry)"
  } else {
    ""
  }

  $git_root | path join $config_dir_name | path join $"($file.stem)($suffix).($file.extension)"
}

def find [
  name: string
  start: path
  ceiling: path
] {
  log debug $"Searching for ($name) in ($start) with ceiling ($ceiling)..."
  mut start = $start
  while $start != $ceiling and $start != "" {
    let path = ($start | path join $name)
    if ($path | path exists) {
      log debug $"Found ($name) at ($path)"
      return $path
    }

    $start = ($start | path dirname)
  }

  # Reached the ceiling without finding the file
  log debug $"Reached ceiling ($ceiling) without finding ($name)"
  null
}
