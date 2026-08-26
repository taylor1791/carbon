# Unit tests for carbon's internal functions.
#
# These call the functions directly instead of driving them through a whole
# push/pull round trip, so they can reach error branches that the end-to-end
# tests cannot construct. No crypto, no registry -- just a git repo, because
# carbon reads `git rev-parse --show-toplevel` at load time.

setup() {
  load helper
  _common_setup
  bare_repo
}

# --- template ---------------------------------------------------------------

@test "template substitutes a single variable" {
  run carbon_call template '"hello {{name}}"' '{"name":"world"}'
  assert_success
  assert_output "hello world"
}

@test "template substitutes every occurrence of a variable" {
  run carbon_call template '"{{a}}-{{a}}-{{a}}"' '{"a":"x"}'
  assert_success
  assert_output "x-x-x"
}

@test "template substitutes multiple distinct variables" {
  run carbon_call template '"{{scheme}}://{{host}}/{{path}}"' \
    '{"scheme":"https","host":"example.com","path":"api"}'
  assert_success
  assert_output "https://example.com/api"
}

@test "template leaves unknown placeholders untouched" {
  run carbon_call template '"{{known}} and {{unknown}}"' '{"known":"yes"}'
  assert_success
  assert_output "yes and {{unknown}}"
}

@test "template handles dotted variable names" {
  run carbon_call template '"registry={{carbon.registry}}"' '{"carbon.registry":"dev"}'
  assert_success
  assert_output "registry=dev"
}

@test "template returns the input unchanged when there are no variables" {
  run carbon_call template '"nothing to do"' '{}'
  assert_success
  assert_output "nothing to do"
}

@test "template coerces non-string values to strings" {
  run carbon_call template '"port {{port}}"' '{"port":8080}'
  assert_success
  assert_output "port 8080"
}

# --- find_expression --------------------------------------------------------

@test "find_expression accepts a bare record" {
  run carbon_call find_expression '"dev"' '{"value":"only"}' '"key"'
  assert_success
  assert_output --partial '"value":"only"'
}

@test "find_expression picks the entry whose registry_pattern matches" {
  run carbon_call find_expression '"dev"' \
    '[{"registry_pattern":"dev","value":"D"},{"value":"DEFAULT"}]' '"key"'
  assert_success
  assert_output --partial '"value":"D"'
}

@test "find_expression falls back to the default when no pattern matches" {
  run carbon_call find_expression '"prd"' \
    '[{"registry_pattern":"dev","value":"D"},{"value":"DEFAULT"}]' '"key"'
  assert_success
  assert_output --partial '"value":"DEFAULT"'
}

@test "find_expression matches registry_pattern as a regex, not a literal" {
  run carbon_call find_expression '"staging-2"' \
    '[{"registry_pattern":"^stag","value":"S"},{"value":"DEFAULT"}]' '"key"'
  assert_success
  assert_output --partial '"value":"S"'
}

@test "find_expression errors when nothing matches and there is no default" {
  run carbon_call find_expression '"prd"' \
    '[{"registry_pattern":"dev","value":"D"}]' '"conn_url"'
  assert_failure
  assert_message "No matching registry patterns for attribute conn_url in registry prd"
}

@test "find_expression errors when two defaults are present" {
  run carbon_call find_expression '"dev"' \
    '[{"value":"A"},{"value":"B"}]' '"conn_url"'
  assert_failure
  assert_message "Multiple default patterns for attribute conn_url in registry dev"
}

@test "find_expression errors when two registry_patterns match" {
  run carbon_call find_expression '"dev"' \
    '[{"registry_pattern":"de","value":"A"},{"registry_pattern":"ev","value":"B"}]' '"conn_url"'
  assert_failure
  assert_message "Multiple matching registry patterns for attribute conn_url in registry dev"
}

# --- resolve ----------------------------------------------------------------

@test "resolve returns a templated value" {
  run carbon_call resolve '{"value":"host-{{carbon.registry}}"}' '"."' '{"carbon.registry":"dev"}'
  assert_success
  assert_output "host-dev"
}

@test "resolve runs a command and trims its output" {
  run carbon_call resolve '{"command":"echo  spaced  "}' '"."' '{}'
  assert_success
  assert_output "spaced"
}

@test "resolve errors when given neither a value nor a command" {
  run carbon_call resolve '{"nonsense":true}' '"."' '{}'
  assert_failure
  assert_message "must contain either a value or a command"
}

# --- execute ----------------------------------------------------------------

@test "execute defaults to sh -c" {
  run carbon_call execute '{"command":"echo ${0##*/}"}' '"."' '{}'
  assert_success
  assert_output "sh"
}

@test "execute honours an explicit shell" {
  run carbon_call execute '{"shell":"nu -c","command":"[1 2 3] | math sum"}' '"."' '{}'
  assert_success
  assert_output "6"
}

@test "execute templates the command before running it" {
  run carbon_call execute '{"command":"echo {{carbon.registry}}-jobs"}' '"."' '{"carbon.registry":"prd"}'
  assert_success
  assert_output "prd-jobs"
}

@test "execute runs the command in the working directory" {
  mkdir -p nested/dir
  echo "found me" > nested/dir/marker
  run carbon_call execute '{"command":"cat marker"}' '"nested/dir"' '{}'
  assert_success
  assert_output "found me"
}

@test "run errors when the command produces no output" {
  run carbon_call run '{"command":"true"}' '"."' '{}'
  assert_failure
  assert_message "Command true returned no output"
}

# --- config_path ------------------------------------------------------------

@test "config_path resolves the default registry" {
  run carbon_eval 'config_path "registry.yaml" | path basename'
  assert_success
  assert_output "registry.yaml"
}

@test "config_path suffixes a named registry before the extension" {
  run carbon_eval 'config_path "registry.yaml" --registry "dev" | path basename'
  assert_success
  assert_output "registry.dev.yaml"
}

@test "config_path suffixes the sops config too" {
  run carbon_eval 'config_path "sops.yaml" --registry "prd" | path basename'
  assert_success
  assert_output "sops.prd.yaml"
}

@test "config_path places config inside the .carbon directory" {
  run carbon_eval 'config_path "registry.yaml" | path dirname | path basename'
  assert_success
  assert_output ".carbon"
}

# --- find -------------------------------------------------------------------

@test "find locates a file in the starting directory" {
  mkdir -p a/b
  touch a/b/carbon.toml
  run carbon_eval "find \"carbon.toml\" \"$BATS_TEST_TMPDIR/a/b\" \"$BATS_TEST_TMPDIR\" | path basename"
  assert_success
  assert_output "carbon.toml"
}

@test "find walks up to an ancestor directory" {
  mkdir -p a/b/c
  touch a/carbon.toml
  run carbon_eval "find \"carbon.toml\" \"$BATS_TEST_TMPDIR/a/b/c\" \"$BATS_TEST_TMPDIR\" | path dirname | path basename"
  assert_success
  assert_output "a"
}

@test "find stops at the ceiling and returns null" {
  mkdir -p a/b
  touch carbon.toml
  run carbon_eval "find \"carbon.toml\" \"$BATS_TEST_TMPDIR/a/b\" \"$BATS_TEST_TMPDIR\" | to json"
  assert_success
  assert_output "null"
}

# --- detect_cycles ----------------------------------------------------------

@test "detect_cycles finds nothing in an acyclic graph" {
  run carbon_call detect_cycles \
    '[{"name":"a","dependencies":["b"]},{"name":"b","dependencies":["c"]},{"name":"c","dependencies":[]}]'
  assert_success
  assert_output "[]"
}

@test "detect_cycles finds a two-service cycle" {
  run carbon_call detect_cycles \
    '[{"name":"a","dependencies":["b"]},{"name":"b","dependencies":["a"]}]'
  assert_success
  assert_output --partial '"a"'
  assert_output --partial '"b"'
}

@test "detect_cycles finds a three-service cycle" {
  run carbon_call detect_cycles \
    '[{"name":"a","dependencies":["b"]},{"name":"b","dependencies":["c"]},{"name":"c","dependencies":["a"]}]'
  assert_success
  assert_output --partial '"c"'
}

@test "detect_cycles ignores dependencies on unknown services" {
  run carbon_call detect_cycles \
    '[{"name":"a","dependencies":["ghost"]}]'
  assert_success
  assert_output "[]"
}
