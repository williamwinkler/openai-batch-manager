# Docker Usage

This project includes a production-ready Dockerfile. The container stores the database and batch files in `/data`, which should be mounted as a volume for persistence.

## Quick Start

### Build the Image

```bash
docker build -t openai-batch-manager:latest .
```

### Run with Docker

The simplest way to run - just pass your OpenAI API key and mount a data volume:

```bash
# Run the container (SECRET_KEY_BASE is auto-generated if not provided)
docker run -d \
  --name openai-batch-manager \
  -p 4000:4000 \
  -v $(pwd)/data:/data \
  -e OPENAI_API_KEY="your-api-key-here" \
  openai-batch-manager:latest
```

### Run with Docker Compose

1. Copy the example compose file:
   ```bash
   cp docker-compose.example.yml docker-compose.yml
   ```

2. Edit `docker-compose.yml` and set your environment variables:
   ```bash
   # Generate secret key
   export SECRET_KEY_BASE=$(mix phx.gen.secret)

   # Set in docker-compose.yml or use .env file
   ```

3. Start the service:
   ```bash
   docker-compose up -d
   ```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENAI_API_KEY` | ✅ Yes | - | Your OpenAI API key |
| `SECRET_KEY_BASE` | No | Auto-generated | Secret for signing cookies (auto-generated if not set) |
| `DATABASE_PATH` | No | `/data/batcher.db` | SQLite database file path |
| `BATCH_STORAGE_PATH` | No | `/data/batches` | Directory for batch files |
| `PORT` | No | `4000` | HTTP port to listen on |
| `PHX_HOST` | No | `localhost` | Hostname for the application |
| `POOL_SIZE` | No | `1` | Database pool size (keep at 1 for SQLite) |

## Volume Mounts

The container expects a volume mounted at `/data` containing:
- Database file: `/data/batcher.db` (created automatically)
- Batch files: `/data/batches/` (created automatically)

**Example:**
```bash
# Create local data directory
mkdir -p ./data

# Mount it in the container
docker run -v $(pwd)/data:/data ...
```

## Database Migrations

Migrations run automatically on container startup:
- **First run**: Creates the database and runs all migrations
- **Upgrades**: When you replace an old container with a new version, pending migrations are automatically detected and applied
- **Safe**: Already-run migrations are skipped (idempotent)

## Health Check

The container includes a health check that verifies the application is responding. Check status with:

```bash
docker ps  # Look for "healthy" status
```

## Accessing the Application

Once running, access:
- Main application: http://localhost:4000
- Oban dashboard: http://localhost:4000/oban
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

### Installing Erlang and Elixir with asdf

This project uses [asdf](https://asdf-vm.com/) for version management. The required versions are specified in `.tool-versions`.

**If you have Erlang/Elixir installed via Homebrew or other methods, uninstall them first:**

```bash
# Uninstall Homebrew versions (if installed)
brew uninstall erlang elixir
```

**Set up asdf:**

1. **Install asdf** (if not already installed):
   ```bash
   brew install asdf
   ```

2. **Add asdf to your shell** (add to `~/.zshrc` or `~/.bashrc`):
   ```bash
   echo -e "\n# asdf version manager\n. $(brew --prefix asdf)/libexec/asdf.sh" >> ~/.zshrc
   ```

3. **Reload your shell configuration:**
   ```bash
   source ~/.zshrc
   ```

4. **Install asdf plugins:**
   ```bash
   asdf plugin add erlang
   asdf plugin add elixir
   ```

5. **Install the versions specified in `.tool-versions`:**
   ```bash
   asdf install
   ```

6. **Verify installation:**
   ```bash
   asdf current
   erl -version
   elixir --version
   ```

**If you encounter build errors:**

If `asdf install` fails with C++ compilation errors (e.g., `'initializer_list' file not found`), you may need to:

- **Add Erlang build configuration** to disable JIT (add to `~/.zshrc`):
  ```bash
  echo -e "\n# Erlang build configuration (disable JIT for compatibility)\nexport KERL_CONFIGURE_OPTIONS=\"--disable-jit\"" >> ~/.zshrc
  source ~/.zshrc
  ```

- **Install build dependencies** (if missing):
  ```bash
  brew install unixodbc openssl@3
  ```

Then retry `asdf install`. These steps are typically only needed on certain macOS/Xcode versions.

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
