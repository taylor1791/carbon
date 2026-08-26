#!/usr/bin/env bash
# Shared fixtures and assertions for carbon's test suite.
#
# Every test runs in its own $BATS_TEST_TMPDIR, so nothing here needs to clean
# up after itself and no test can observe another test's registry.

# The carbon under test. Defaults to the working tree; CI overrides it with the
# nix-built wrapper so the same suite covers both artifacts.
: "${CARBON_BIN:=${BATS_TEST_DIRNAME}/../carbon}"

_common_setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  # rage writes to $HOME; keep it inside the fixture.
  export HOME="$BATS_TEST_TMPDIR"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# A git repo with carbon in it, but no keys and no registry.
#
# carbon resolves every path from `git rev-parse --show-toplevel`, so the
# fixture has to be a real repo -- and deliberately not the one under test.
bare_repo() {
  git init -q -b main .
  install_carbon
  git add -A
  git -c user.email=test@example.com -c user.name=test commit -qm fixture
}

# A git repo with carbon bootstrapped for each named user.
#
# Each user gets their own key, saved as .carbon/private-key.age.<user>, and the
# first user is left active. Switch with `as_user`.
carbon_repo() {
  local users=("$@")
  [ ${#users[@]} -eq 0 ] && users=(alice)

  bare_repo
  for u in "${users[@]}"; do
    USER="$u" ./carbon init >/dev/null 2>&1 || return 1
    mv .carbon/private-key.age ".carbon/private-key.age.$u"
  done
  as_user "${users[0]}"
}

as_user() {
  cp ".carbon/private-key.age.$1" .carbon/private-key.age
}

# Grants the named users access to a registry, as the user who already has it.
#
# request adds the key as a recipient; rekey re-encrypts the data key for them.
grant_access() {
  local granter="$1"; shift
  local registries=()
  local users=()
  local seen_sep=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen_sep=1; continue; fi
    if [ $seen_sep -eq 1 ]; then registries+=("$a"); else users+=("$a"); fi
  done

  for u in "${users[@]}"; do
    as_user "$u"
    USER="$u" ./carbon request "${registries[@]}" >/dev/null 2>&1
  done
  as_user "$granter"
  ./carbon rekey "${registries[@]}" >/dev/null 2>&1
}

# Writes a service's carbon.toml from a heredoc and returns nothing.
#
#   service svc <<'TOML'
#   [push.url]
#   value = "https://example.com"
#   TOML
#
# The service name defaults to the directory name; pass --name to override.
service() {
  local dir="$1"; shift
  local name="$dir"
  if [ "${1:-}" = "--name" ]; then name="$2"; shift 2; fi

  mkdir -p "$dir"
  { echo "name = \"$name\""; cat; } > "$dir/carbon.toml"
}

# Evaluates a nushell expression with carbon's internals in scope.
#
# `source` needs a parse-time constant, so the path is interpolated into the
# script text rather than passed as a variable.
carbon_eval() {
  nu --no-config-file -c "source $BATS_TEST_TMPDIR/carbon
$1"
}

# Calls one of carbon's internal functions with JSON-encoded arguments.
#
#   carbon_call find_expression '"dev"' '[{"value":"x"}]' '"key"'
#
# Strings print bare; anything else prints as compact JSON.
carbon_call() {
  local fn="$1"; shift
  local call="$fn"
  local i=0
  for _ in "$@"; do call="$call (\$a.$i)"; i=$((i + 1)); done

  local args_json
  args_json="[$(IFS=,; echo "$*")]"

  CARBON_ARGS="$args_json" carbon_eval "
let a = (\$env.CARBON_ARGS | from json)
let out = ($call)
if (\$out | describe) == 'string' { print \$out } else { print (\$out | to json -r) }"
}

# Asserts a registry value by decrypting it, not by looking for a ciphertext key.
assert_registry() {
  local svc="$1" key="$2" expected="$3" registry="${4:-}"
  local actual
  if [ -n "$registry" ]; then
    actual="$(./carbon read -r "$registry" "$svc" "$key")"
  else
    actual="$(./carbon read "$svc" "$key")"
  fi
  assert_equal "$actual" "$expected"
}

# Asserts a key in the service's pulled environment file.
assert_env() {
  local file="$1" key="$2" expected="$3"
  assert_equal "$(jq -r --arg k "$key" '.[$k]' "$file")" "$expected"
}

# Asserts a substring of an error message, ignoring nushell's line wrapping.
#
# nu renders errors in a box and hard-wraps long messages, so a message written
# as one line in the source arrives split across two with a `|` gutter.
assert_message() {
  local flat
  flat="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/|/ /g; s/  */ /g')"
  case "$flat" in
    *"$1"*) return 0 ;;
    *)
      batslib_print_kv_single_or_multi 8 "substring" "$1" "flattened output" "$flat" \
        | batslib_decorate "message does not contain substring" | fail
      ;;
  esac
}

# Installs the carbon under test at ./carbon inside the fixture.
#
# The checked-in script starts with `#!/usr/bin/env nu`, and /usr/bin/env does
# not exist inside a nix build sandbox. Rewrite the shebang to the nushell on
# PATH so `./carbon` works everywhere. The packaged wrapper already carries an
# absolute shebang and is copied as-is.
install_carbon() {
  cp "$CARBON_BIN" carbon
  chmod +x carbon
  if head -n 1 carbon | grep -q 'env nu$'; then
    sed -i "1s|.*|#!$(command -v nu)|" carbon
  fi
}
