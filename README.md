# Docker Usage & Batch File Storage


This project stores temporary batch files in `/data` inside the container. For both development and production, mount a local directory to `/data` for easy access and persistence.

## Docker Run Example



To run the application and persist batch files, mount a volume to `/data`:

```sh
docker run \
   -v $(pwd)/data:/data \
   -e DATABASE_URL=sqlite:///data/db.sqlite3 \
   -p 4000:4000 \
   openai-batch-manager:latest
```

## Docker Compose Example

```yaml
version: '3.8'
services:
   batcher:
      image: openai-batch-manager:latest
      ports:
         - "4000:4000"
      environment:
         - DATABASE_URL=sqlite:///var/lib/openai-batch-manager/db.sqlite3
         volumes:
         - ./data:/data
```

**Note:**
- The host directory `./data` will persist batch files outside the container.
- You can change the host path as needed, but the container path must remain `/data`.
# LLM Batch Manager

A Phoenix 1.8.1 web application built with the Ash Framework for managing batching of LLM prompts for processing by providers like OpenAI.

## Tech Stack

- Phoenix 1.8.1 + Ash Framework 3.0 (domain-driven development)
- Database: SQLite with AshSqlite adapter
- Job Queue: Oban 2.0 for background processing
- State Management: AshStateMachine extension
- Admin Dashboard: AshAdmin (dev only)
- Styling: Tailwind v4 + daisyUI

## Getting Started

### Prerequisites

- Elixir 1.18+ and Erlang/OTP 27+
- SQLite 3.x

### Setup on a New Machine

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd llm-batch-manager
   ```

2. **Install dependencies**
   ```bash
   mix setup
   ```
   This will install Elixir and Node.js dependencies, create and migrate the database.

3. **Start the Phoenix server**
   ```bash
   mix phx.server
   ```
   Or inside IEx for interactive development:
   ```bash
   iex -S mix phx.server
   ```

4. **Visit the application**
   - Main app: [http://localhost:4000](http://localhost:4000)
   - AshAdmin dashboard: [http://localhost:4000/admin](http://localhost:4000/admin)
   - Oban dashboard: [http://localhost:4000/oban](http://localhost:4000/oban)

## Development Commands

> **⚠️ Important:** This is an **Ash Framework** project. Always prefer `mix ash.*` commands over `mix ecto.*` commands when available.

### Ash Framework Commands

**Migration and code generation:**
```bash
# Generate migrations based on resource schema changes
mix ash.codegen initial_migration

# Run all Ash migrations
mix ash.migrate

# Rollback Ash migrations
mix ash.rollback

# View migration snapshots
ls priv/resource_snapshots/
```

**Database management (prefer over ecto):**
```bash
# Setup database (create, migrate, seed)
mix ash.setup

# Reset database (tear down and setup)
mix ash.reset

# Tear down database
mix ash.tear_down
```

**Resource and domain generation:**
```bash
# Generate a new Ash domain
mix ash.gen.domain Batcher.NewDomain

# Generate a new Ash resource
mix ash.gen.resource Batcher.Batching.NewResource

# Add extension to existing resource/domain
mix ash.extend Batcher.Batching.Batch AshStateMachine

# Generate custom modules
mix ash.gen.change Batcher.Batching.Changes.MyChange
mix ash.gen.validation Batcher.Batching.Validations.MyValidation
mix ash.gen.preparation Batcher.Batching.Preparations.MyPreparation
mix ash.gen.enum Batcher.Batching.StatusEnum
```

**Documentation and visualization:**
```bash
# Generate Livebook notebooks for domains
mix ash.generate_livebook

# Generate Mermaid resource diagrams
mix ash.generate_resource_diagrams

# Generate policy charts
mix ash.generate_policy_charts
```

### Ecto Commands (fallback only)

```bash
# Use these only when Ash commands are not available

# Create database (prefer: mix ash.setup)
mix ecto.create

# Run migrations (prefer: mix ash.migrate)
mix ecto.migrate

# Rollback (prefer: mix ash.rollback)
mix ecto.rollback

# Reset database (prefer: mix ash.reset)
mix ecto.reset

# View migration status
mix ecto.migrations
```

### Testing

```bash
# Run all tests
mix test

# Run specific test file
mix test test/batcher/batching_test.exs

# Run tests that previously failed
mix test --failed

# Run tests with coverage
mix test --cover
```

### Code Quality

```bash
# Run pre-commit checks (format, compile, test)
mix precommit

# Format code
mix format

# Check for compilation warnings
mix compile --warnings-as-errors
```

### Asset Management

```bash
# Install Node.js dependencies
cd assets && npm install

# Build assets for development
mix assets.build

# Build assets for production
mix assets.deploy
```

## Architecture

This application uses **Ash Framework** for domain-driven development. Instead of traditional Phoenix Contexts, business logic is defined in **Ash Resources** organized into **Domains**.

### Key Resources

- **Batch** - Collections of prompts with 11-state workflow
- **Prompt** - Individual LLM prompts with 8-state workflow
- **BatchTransition** / **PromptTransition** - Automatic audit trails

### State Machines

Both Batch and Prompt resources use the `AshStateMachine` extension to manage complex workflows with automatic validation and audit trails.

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.

## Learn More

### Phoenix
- Official website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix

### Ash Framework
- Official website: https://ash-hq.org/
- Guides: https://hexdocs.pm/ash/get-started.html
- Docs: https://hexdocs.pm/ash

### Deployment
- [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html)
- [Ash deployment considerations](https://hexdocs.pm/ash/deployment.html)
