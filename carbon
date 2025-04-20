#!/home/taylor1791/src/nushell/target/release/nu

use std/log

let name = "carbon"
let version = "0.0.1"
let git_root = git rev-parse --show-toplevel # | complete
let config_dir_name = $".($name)"
let service_config_name = $"($name).toml"
let relative_private_key = ($config_dir_name | path join "private-key.age")
let private_key_file = ($git_root | path join $relative_private_key)

# Secrets managements for monorepo-based service-oriented architectures.
def main [] {
  help main
}

# Initializes secrets management for a service
def "main init" [
  service: string
  --namespace (-n): list<string> = [""]
] {
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

  main request --namespace $namespace --only-if-created

  for $ns in $namespace {
    read_sops_config $ns
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

# Pushes secrets to the registry.
def "main push" [
  service?: string # The path of the service from which to publish secrets.
] {
  let working_dir = read_working_dir $service
  let service_config = open ($working_dir | path join $service_config_name)
  let namespace = read_namespace $service_config $working_dir
  let sops = read_sops_config $namespace

  let service_name = $service_config | get name | to json --raw
  let publish = $service_config | get push? | default {}
  for secret_name in ($publish | columns) {
    let expression = find_expression $namespace ($publish | get $secret_name) $secret_name
    let secret = resolve $expression $working_dir | to json --raw
    log debug $"Publishing secret ($secret_name) with value: ($secret)"

    with-env {
      SOPS_AGE_KEY_FILE: $private_key_file 
    } {
      let set_value = $'[($service_name)][($secret_name | to json --raw)] ($secret)'
      sops --config $sops.config_path --set $set_value -i $sops.registry_path
    }
  }
}

# Pull secrets from the registry.
def "main pull" [
  service?: string # The path of the service from which to pull secrets.
] {
  let working_dir = read_working_dir $service
  let service_config = open ($working_dir | path join $service_config_name)
  let namespace = read_namespace $service_config $working_dir
  let sops = read_sops_config $namespace

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
        [_, $err] if $err =~ "component \\[.*\\] not found" and 'default' in $definition =>
          (resolve ($definition | get default) $working_dir),
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

# Changes the namespace of a service.
def "main use" [
  namespace: string
  service?: string
] {
  let working_dir = read_working_dir $service
  let service_config = open ($working_dir | path join $service_config_name)

  if not ('use' in ($service_config | get namespace? | default {})) {
    error make -u {
      msg: $"The service ("FIXME") does not support changing namespaces."
    }
  }

  let variables = {
    namespace: $namespace
  }

  execute ($service_config | get namespace.use) $working_dir $variables
}

# Generates a private key and adds it to the recipients list.
def "main request" [
  --namespace (-n): list<string> = [""]
  --only-if-created # Only add the user's key if the config file was created.
] {
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
  for $ns in $namespace {
    let sops_config_file = ($git_root | config_path "sops.yaml" --namespace $ns)
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

# Accepts pending access changes and rotates the registry key if any users were removed.
def "main rekey" [
  --namespace (-n): list<string> = [""]
] {
  for ns in $namespace {
    let sops = read_sops_config $ns

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

def read_namespace [
  service_config: record
  working_dir: path
] {
  let service_namespace = $service_config | get namespace? | default {}

  if not ('current' in $service_namespace) {
    log debug "Using default namespace since service has no namespace.current."
    return ""
  }

  let value = resolve $service_namespace.current $working_dir
  log debug $"Using value from namespace.current: ($value)"

  return $value
}

def read_sops_config [
  namespace: string
] {
  let registry_path = config_path "registry.yaml" --namespace $namespace
  let sops_config_path = ($git_root | config_path "sops.yaml" --namespace $namespace)
  if not ($registry_path | path exists) {
    log debug $"Creating registry file ($registry_path)"
    { $"_($name)": { version: $version } } | save $registry_path
    sops --config $sops_config_path --encrypt -i $registry_path
  }

  { registry_path: $registry_path config_path: $sops_config_path }
}

def find_expression [
  namespace: string
  expressions
  name: string
] {
  let expressions = if ($expressions | describe) == "list" { $expressions } else { [$expressions] }

  let matched = $expressions | where {|expression|
    let namespace_pattern = $expression | get namespace_pattern? | default "^"

    $namespace =~ $namespace_pattern
  }

  match ($matched | length) {
    0 => (error make -u {
      msg: $"No matching namespace patterns for attribute ($name) in namespace ($namespace)."
    }),
    1 => ($matched | first),
    _ => (error make -u {
      msg: "Multiple matching namespace patterns for attribute ($name) in namespace ($namespace)."
    })
  }
}

def resolve [
  record: record
  working_dir: path
  variables: record = {}
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
  variables: record = {}
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
  variables: record = {}
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
  --namespace: string = ""
] {
  let file = $filename | path parse

  let suffix = if $namespace != "" {
    $".($namespace)"
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
