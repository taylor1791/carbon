Carbon
======

Encrypted local configuration for monorepo-based service-oriented architectures.

Services in a monorepos expose configuration to other services and consume configuration
from other services. When using Carbon a service code-ifys this in a carbon.toml file.
All of the published configuration is encrypted and stored in a registry. Registries are
stored in the monorepo and use envelope encrypted to allow specific users to decrypt a
registry. Registries are named and isolated to facilitate different environment.

**You should not use Carbon.** This was built as a proof of concept to demonstrate how
one might securely avoid a central configuration service. It is not a production ready
system.

## Commands

| Command   | Description                                                        |
|-----------|--------------------------------------------------------------------|
| `init`    | Bootstraps registries and initializes services.                    |
| `push`    | Pushes a service's exposed configuration to the registry.          |
| `pull`    | Pulls a service's configuration from the registry.                 |
| `run`     | Runs a command with pulled secrets and derives as environment variables. |
| `use`     | Changes the registry used by a service.                            |
| `request` | Request access to a registry.                                      |
| `rekey`   | Applies pending access changes.                                    |
| `view`    | Views the registry.                                                |
| `read`    | Read a single value from the registry.                             |
| `check`   | Checks the dependency graph for errors and warnings.               |
| `graph`   | Outputs the service dependency graph in DOT (Graphviz) format.     |

## Configuration (`carbon.toml`)

Each service has a `carbon.toml` that defines what it pushes, pulls, and derives.

### Top-level fields

- **`name`** (required) — unique service identifier.
- **`file`** (optional) — output filename for pulled configuration. Defaults to
  `.environment.json`.

### `[pull.<name>]` — import secrets from other services

| Field     | Required | Description                                              |
|-----------|----------|----------------------------------------------------------|
| `service` | yes      | Name of the service that publishes the secret.           |
| `name`    | no       | Key in the target service's push. Defaults to `<name>`.  |
| `default` | no       | Fallback expression if the secret is not yet published.  |

```toml
[pull.database_url]
service = "db-service"
name = "connection_string"
default = { value = "sqlite://localhost" }
```

### `[push.<name>]` — export secrets for other services

A push entry can be a static value, a command, or an array of registry-pattern variants.

| Field              | Description                                                   |
|--------------------|---------------------------------------------------------------|
| `value`            | Static string value.                                          |
| `command`          | Shell command whose stdout becomes the value.                 |
| `shell`            | Shell to execute in (default `sh -c`).                        |
| `registry_pattern` | Regex matched against the registry name (array form only).    |
| `expect_unused`    | Suppress "unused push key" warnings from `check`.             |

```toml
# Static value
[push.api_key]
value = "my-secret"

# Command
[push.generated_token]
command = "cat secrets.json | jq -r '.token'"

# Registry-pattern variants (use [[push.<name>]])
[[push.service_url]]
registry_pattern = "dev"
value = "http://localhost:3000"

[[push.service_url]]
registry_pattern = "prd"
value = "https://api.example.com"

[[push.service_url]]
value = "http://localhost:3000"
```

### `[derive.<name>]` — compose values from pulls

Derives create new values by interpolating pulled secrets using `{{pull.<key>}}`
templates. Derived values appear alongside pulls in the output file and as environment
variables in `carbon run`.

| Field              | Description                                                   |
|--------------------|---------------------------------------------------------------|
| `value`            | Template string with `{{pull.<key>}}` placeholders.           |
| `registry_pattern` | Regex matched against the registry name (array form only).    |

```toml
# Simple derive
[derive.pool_url]
value = "{{pull.database_url}}?poolSize=10"

# Registry-pattern variants (use [[derive.<name>]])
[[derive.conn_url]]
registry_pattern = "dev"
value = "http://{{pull.host}}:3000"

[[derive.conn_url]]
registry_pattern = "prd"
value = "https://{{pull.host}}"

[[derive.conn_url]]
value = "http://{{pull.host}}:8080"
```

### `[registry]` — configure registry selection

| Field     | Description                                                           |
|-----------|-----------------------------------------------------------------------|
| `current` | Expression that returns the current registry name.                    |
| `use`     | Expression run when `carbon use <registry>` is called for the service.|

```toml
[registry]
current = { command = "cat .registry" }
use = { command = "echo {{carbon.registry}} > .registry" }
```

### Template variables

| Variable              | Available in           | Description               |
|-----------------------|------------------------|---------------------------|
| `{{carbon.registry}}` | push, derive, registry | Current registry name.    |
| `{{pull.<key>}}`      | derive                 | Resolved value of a pull. |

## Example Workflow

```sh
# 1. Initialize — create a registry and a service
carbon init --registries [dev] .carbon/my-service

# 2. Push — publish the service's secrets to the registry
carbon push .carbon/my-service

# 3. Pull — fetch secrets from the registry into .environment.json
carbon pull .carbon/my-service

# 4. Run — execute a command with secrets as environment variables
carbon run --service .carbon/my-service my-app --serve
```

## Future Work
I do not intend to build this out further, but if I were these ideas would guide me.

- *Per-service Access Control*: This implementation uses access control at the registry
  level. It would be possible to use a more fine-grained access control system that
  allows for per-service access control.
- *Nushell*: Nushell is great for hacking, but the error messages are unfamiliar to the
  uninitiated.
