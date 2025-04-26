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

## Future Work
I do not intend to build this out further, but if I were these ideas would guide me.

- *Circular Dependency Detection*: Since carbon.toml explicitly defines dependencies
  between services, it is possible to detect circular dependencies between services.
- *Per-service Access Control*: This implementation uses access control at the registry
  level. It would be possible to use a more fine-grained access control system that
  allows for per-service access control.
- *Nushell*: Nushell is great for hacking, but the error messages are unfamiliar to the
  uninitiated.

