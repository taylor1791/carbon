# Changelog

All notable changes to carbon are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.0.3] - 2026-08-25

### Changed

- **Breaking:** `init` takes service paths as positional arguments and scaffolds
  each one: `carbon init svc-a svc-b`. It no longer creates named registries;
  the `--registries (-r)` flag is removed.
- **Breaking:** `request` and `rekey` take registries as positional arguments:
  `carbon request dev prd`, `carbon rekey dev prd`. Their `--registries (-r)`
  flags are removed. With no arguments, both operate on the default registry.
- **Breaking:** the `{{registry}}` template variable is now namespaced as
  `{{carbon.registry}}`.
- `request` now creates the encrypted registry file (previously only `init`
  did) and is idempotent: requesting access twice does not duplicate the
  user's key.

### Added

- `run` subcommand: executes a command with pulled secrets and derives as
  environment variables, propagating the command's exit code.
- `check` subcommand: validates the dependency graph — duplicate service names,
  missing services and push keys, circular dependencies, unused push keys,
  derive/pull collisions, invalid derive references, and `{{env.<key>}}`
  references in push values.
- `graph` subcommand: emits the service dependency graph in DOT format.
- `[derive]` section for composing values from pulls, with `registry_pattern`
  variants and `{{env.<key>}}` template variables resolved from the shell
  environment at pull time.
- `expect_unused` option on push keys to suppress unused-key warnings from
  `check`.

### Fixed

- Registry arguments were impossible to pass from a shell: nushell passes
  script arguments as strings, so flags typed `list<string>` could never be
  satisfied — `carbon init -r "[dev]"` always failed to parse. Positional rest
  arguments (see Changed) are typed `list<string>` natively from argv.

### Migration

| Before | After |
|---|---|
| `carbon init -r "[dev, prd]" my-service` | `carbon init my-service` then `carbon request dev prd` |
| `carbon init my-service` | unchanged |
| `carbon request -r "[dev]"` | `carbon request dev` |
| `carbon rekey -r "[dev, prd]"` | `carbon rekey dev prd` |
| `{{registry}}` in `carbon.toml` | `{{carbon.registry}}` |

## [0.0.2] - 2026-03-17

- `view` and `read` commands for inspecting a registry.
- Template values with `{{registry}}` expansion in push values and default
  commands.
- `registry_pattern` variants for push tables.
- `init` service argument became optional.

## [0.0.1] - 2025-04-20

- Initial proof of concept: `init`, `push`, `pull`, `use`, `request`, and
  `rekey` over sops/age-encrypted registries.
