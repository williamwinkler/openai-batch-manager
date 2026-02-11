---
name: ash-framework
description: "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [ash](references/ash.md)
- [ash_phoenix](references/ash_phoenix.md)
- [ash_json_api](references/ash_json_api.md)
- [ash_state_machine](references/ash_state_machine.md)
- [ash_sqlite](references/ash_sqlite.md)
- [ash_oban](references/ash_oban.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ash -p ash_phoenix -p ash_json_api -p ash_state_machine -p ash_sqlite -p ash_oban
```

## Available Mix Tasks

- `mix ash` - Prints Ash help information
- `mix ash.codegen` - Runs all codegen tasks for any extension on any resource/domain in your application.
- `mix ash.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.gen.base_resource` - Generates a base resource. This is a module that you can use instead of `Ash.Resource`, for consistency.
- `mix ash.gen.change` - Generates a custom change module.
- `mix ash.gen.custom_expression` - Generates a custom expression module.
- `mix ash.gen.domain` - Generates an Ash.Domain
- `mix ash.gen.enum` - Generates an Ash.Type.Enum
- `mix ash.gen.preparation` - Generates a custom preparation module.
- `mix ash.gen.resource` - Generate and configure an Ash.Resource.
- `mix ash.gen.validation` - Generates a custom validation module.
- `mix ash.generate_livebook` - Generates a Livebook for each Ash domain
- `mix ash.generate_policy_charts` - Generates a Mermaid Flow Chart for a given resource's policies.
- `mix ash.generate_resource_diagrams` - Generates Mermaid Resource Diagrams for each Ash domain
- `mix ash.install` - Installs Ash into a project. Should be called with `mix igniter.install ash`
- `mix ash.migrate` - Runs all migration tasks for any extension on any resource/domain in your application.
- `mix ash.patch.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.reset` - Runs all tear down & setup tasks for any extension on any resource/domain in your application.
- `mix ash.rollback` - Runs all rollback tasks for any extension on any resource/domain in your application.
- `mix ash.setup` - Runs all setup tasks for any extension on any resource/domain in your application.
- `mix ash.tear_down` - Runs all tear_down tasks for any extension on any resource/domain in your application.
- `mix ash_phoenix.gen.html` - Generates a controller and HTML views for an existing Ash resource.
- `mix ash_phoenix.gen.live` - Generates liveviews for a given domain and resource.
- `mix ash_phoenix.install` - Installs AshPhoenix into a project. Should be called with `mix igniter.install ash_phoenix`
- `mix ash_json_api.install` - Installs AshJsonApi. Should be run with `mix igniter.install ash_json_api`
- `mix ash_json_api.routes` - Prints all routes by AshJsonApiRouter
- `mix ash_state_machine.generate_flow_charts` - Generates Mermaid Flow Charts for each resource using `AshStateMachine`
- `mix ash_state_machine.install` - Installs AshStateMachine
- `mix ash_state_machine.install.docs`
- `mix ash_sqlite.create` - Creates the repository storage
- `mix ash_sqlite.drop` - Drops the repository storage for the repos in the specified (or configured) domains
- `mix ash_sqlite.generate_migrations` - Generates migrations, and stores a snapshot of your resources
- `mix ash_sqlite.install` - Installs AshSqlite. Should be run with `mix igniter.install ash_sqlite`
- `mix ash_sqlite.migrate` - Runs the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_sqlite.rollback` - Rolls back the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_oban.install` - Installs AshOban and Oban
- `mix ash_oban.install.docs`
- `mix ash_oban.set_default_module_names` - Set module names to their default values for triggers and scheduled actions
- `mix ash_oban.set_default_module_names.docs`
- `mix ash_oban.upgrade`
<!-- usage-rules-skill-end -->
