# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenAI Batch Manager is a **Phoenix 1.8.1** web application built with **Ash Framework 3.0** for managing batching of LLM prompts for OpenAI's Batch API. The application aggregates individual requests into batches, uploads them to OpenAI, tracks processing status, downloads results, and delivers responses via webhook or RabbitMQ.

**Tech Stack:**
- Phoenix 1.8.1 + Ash Framework 3.0 (domain-driven development)
- Database: SQLite with AshSqlite adapter (pool_size: 1)
- Job Queue: Oban 2.0 with AshOban integration
- State Management: AshStateMachine extension
- Styling: Tailwind v4 + daisyUI

## Essential Development Commands

### Setup
```bash
# First-time setup (installs deps, creates DB, runs migrations)
mix setup

# Start Phoenix server
mix phx.server

# Start with IEx console
iex -S mix phx.server
```

### Testing
```bash
# Run all tests
mix test

# Run specific test file
mix test test/batcher/batching_test.exs

# Run previously failed tests
mix test --failed

# Run with coverage
mix test --cover
```

### Ash Framework Commands (ALWAYS prefer these over ecto.*)
```bash
# Generate migrations from resource changes
mix ash.codegen initial_migration

# Run migrations
mix ash.migrate

# Rollback migrations
mix ash.rollback

# Setup database (create, migrate, seed)
mix ash.setup

# Reset database (tear down and setup)
mix ash.reset
```

### Code Quality
```bash
# Run all pre-commit checks (format, compile with warnings-as-errors, test)
mix precommit

# Format code
mix format
```

### Application URLs
- Main app: http://localhost:4000
- AshAdmin dashboard: http://localhost:4000/admin (dev only)
- Oban dashboard: http://localhost:4000/oban (dev only)

## Core Architecture

### Ash Framework Domain Model

This application uses **Ash Framework** instead of traditional Phoenix Contexts. All business logic is defined in **Ash Resources** organized into the **`Batcher.Batching`** domain.

**Domain Module:** `lib/batcher/batching.ex`
- Defines the `Batcher.Batching` domain
- Exposes **code interface functions** for calling resource actions
- **ALWAYS** use these domain functions instead of calling `Ash.create!`, `Ash.read!`, etc. directly

**Key Resources:**
1. **`Batcher.Batching.Batch`** (`lib/batcher/batching/batch.ex`)
   - Represents a collection of requests sent to OpenAI
   - 11-state workflow: `building → uploading → uploaded → openai_processing → openai_completed → downloading → ready_to_deliver → delivering → done`
   - Also supports: `failed`, `cancelled`, `expired`

2. **`Batcher.Batching.Request`** (`lib/batcher/batching/request.ex`)
   - Individual LLM request within a batch
   - 8-state workflow: `pending → openai_processing → openai_processed → delivering → delivered`
   - Also supports: `failed`, `delivery_failed`, `expired`, `cancelled`
   - Each request has delivery configuration (webhook URL or RabbitMQ queue)

3. **`Batcher.Batching.BatchTransition`** - Automatic audit trail for batch state changes
4. **`Batcher.Batching.RequestDeliveryAttempt`** - Tracks delivery attempts for requests

### Batch Aggregation System (BatchBuilder)

**`Batcher.BatchBuilder`** (`lib/batcher/batch_builder.ex`) is a critical GenServer that aggregates incoming requests into batches.

**Key Characteristics:**
- One BatchBuilder runs per `{url, model}` combination
- Registered in `Batcher.BatchRegistry` with key `{url, model}`
- Supervised by `Batcher.BatchSupervisor` (DynamicSupervisor)
- Uses `restart: :temporary` (does NOT auto-restart on exit)
- Automatically shuts down when:
  - Batch reaches 50,000 requests (OpenAI limit)
  - Batch is manually uploaded via `:finish_building` call
  - Batch state changes from `:building` to any other state (via PubSub)
  - Batch is destroyed

**Request Flow:**
1. Client calls `BatchBuilder.add_request(url, model, request_data)`
2. BatchBuilder looks up or creates a building batch for that `{url, model}` pair
3. Request is inserted into the batch via `Batcher.Batching.create_request/1`
4. When batch is full or ready, BatchBuilder calls `Batcher.Batching.start_batch_upload/1`
5. BatchBuilder unregisters itself and terminates
6. Next request for same `{url, model}` creates a NEW BatchBuilder with a NEW batch

**Important:** The BatchBuilder listens to PubSub topics `batches:state_changed:#{batch_id}` and `batches:destroyed:#{batch_id}` to automatically shut down when the batch transitions out of `:building` state.

### State Machine Workflow

Both `Batch` and `Request` resources use **AshStateMachine** extension.

**Critical SQLite Requirement:**
- **ALL state transition actions MUST include `require_atomic? false`**
- This is a known limitation of AshSqlite
- Without this, state transitions will fail

Example:
```elixir
update :start_upload do
  require_atomic? false  # REQUIRED for SQLite
  change transition_state(:uploading)
end
```

**Audit Trail:**
- Every state transition is automatically recorded using `Batcher.Batching.Changes.CreateTransition`
- This change is attached to actions via the `changes` block with `where: [changing(:state)]`
- Do NOT manually add this change to individual actions

### Background Job Processing (Oban + AshOban)

The application uses **Oban 2.0** with **AshOban** integration for background jobs.

**Oban Queues:**
- `default` - General background tasks (concurrency: 10)
- `batch_uploads` - File uploads to OpenAI (concurrency: 1)
- `batch_processing` - Downloads and processing (concurrency: 1)
- `delivery` - Webhook/RabbitMQ delivery (concurrency: 50)

**AshOban Triggers:**
Resources define Oban triggers in the `oban` block that automatically schedule background jobs when certain conditions are met:

```elixir
oban do
  triggers do
    trigger :upload do
      action :upload
      where expr(state == :uploading)
      queue :batch_uploads
    end
  end
end
```

**Manual Trigger Execution:**
Actions can manually trigger Oban jobs using `run_oban_trigger/1`:

```elixir
update :start_upload do
  change transition_state(:uploading)
  change run_oban_trigger(:upload)  # Manually enqueue :upload trigger
end
```

### Custom Actions vs Update Actions

Ash resources support **custom actions** that don't follow standard CRUD patterns.

**Custom Action (`:struct` type):**
Used for complex business logic that may require multiple database operations or external API calls:

```elixir
action :check_batch_status, :struct do
  description "Check status of OpenAI batch processing"
  constraints instance_of: __MODULE__
  transaction? false  # Often used for long-running operations
  run Batching.Actions.CheckBatchStatus  # Implemented in separate module
end
```

**When to use custom actions:**
- Making external API calls (OpenAI)
- Downloading/uploading files
- Complex multi-step workflows
- Operations that should NOT run in a transaction

**Implementation Location:** `lib/batcher/batching/actions/`

### Validations and Changes

**Validations** (`lib/batcher/batching/validations/`):
- Validate data before resource actions execute
- Example: `ValidateDeliveryConfig` ensures webhook delivery has `webhook_url` and RabbitMQ delivery has `rabbitmq_queue`

**Changes** (`lib/batcher/batching/changes/`):
- Modify changesets or perform side effects during action execution
- Example: `SetPayload` converts the request payload to JSON string and calculates size
- Example: `UploadBatchFile` uploads the batch file to OpenAI during the `:upload` action

**How to use:**
```elixir
create :create do
  accept [:batch_id, :custom_id]
  validate Batching.Validations.DeliveryConfig
  change Batching.Changes.SetPayload
end
```

### Database Schema Conventions

**SQLite-Specific Configuration:**
- Pool size is always 1 (SQLite limitation)
- Polling interval set to 1000ms to reduce database contention
- All writes are serialized

**Relationships:**
- `Request` belongs to `Batch` (with `on_delete: :delete` cascade)
- `BatchTransition` belongs to `Batch`
- `RequestDeliveryAttempt` belongs to `Request`

**Unique Constraints:**
- `custom_id` must be unique within each batch (composite index on `[:custom_id, :batch_id]`)

### Calculations

Ash resources can define **calculations** that are loaded on-demand:

```elixir
calculations do
  calculate :request_count, :integer, Batcher.Batching.Calculations.BatchRequestCount
  calculate :size_bytes, :integer, Batcher.Batching.Calculations.BatchSizeBytes
end
```

**Loading Calculations:**
```elixir
# Load specific calculations
batch = Batcher.Batching.get_batch_by_id(id, load: [:request_count, :size_bytes])

# Or using Ash.load!
batch = Ash.load!(batch, [:request_count, :size_bytes])
```

**Implementation Location:** `lib/batcher/batching/calculations/`

### OpenAI Integration

The application interacts with OpenAI's Batch API in the following workflow:

1. **Upload Phase** (`Batching.Changes.UploadBatchFile`):
   - Generates `.jsonl` file from batch requests
   - Uploads file to OpenAI via `/v1/files` endpoint
   - Stores `openai_input_file_id` on batch

2. **Batch Creation** (`Batching.Changes.CreateOpenaiBatch`):
   - Creates batch on OpenAI platform via `/v1/batches` endpoint
   - Stores `openai_batch_id` on batch

3. **Status Checking** (`Batching.Actions.CheckBatchStatus`):
   - Polls OpenAI batch status via `/v1/batches/{batch_id}`
   - Triggered periodically by AshOban
   - Updates batch state when OpenAI processing completes

4. **Download Phase** (`Batching.Actions.ProcessDownloadedFile`):
   - Downloads output file from OpenAI
   - Parses `.jsonl` responses
   - Updates each request with `response_payload`
   - Marks batch as `ready_to_deliver`

5. **Delivery Phase** (`Batching.Actions.Deliver`):
   - Sends results to webhook URL or RabbitMQ queue
   - Records delivery attempts in `RequestDeliveryAttempt`
   - AshOban triggers delivery jobs when requests are `openai_processed`

**OpenAI Client:** Uses `:req` library (configured in `config/config.exs` with base URL `https://api.openai.com`)

## Critical Implementation Rules

### Ash Framework Rules

1. **ALWAYS use code interface functions** from the domain module:
   ```elixir
   # CORRECT
   Batcher.Batching.create_batch(model, url)

   # INCORRECT
   Ash.create!(Batcher.Batching.Batch, %{model: model, url: url})
   ```

2. **ALWAYS include `require_atomic? false` on ALL state transition actions** (SQLite requirement)

3. **Load relationships explicitly** - they are NOT loaded by default:
   ```elixir
   batch = Batcher.Batching.get_batch_by_id(id, load: [:requests, :transitions])
   ```

4. **Use Ash.Changeset functions** to access attributes in changes/validations:
   ```elixir
   # CORRECT
   state = Ash.Changeset.get_attribute(changeset, :state)

   # INCORRECT
   state = changeset[:state]
   ```

### Phoenix LiveView Rules

1. **Streams for collections** - Use LiveView streams for rendering lists to avoid memory issues:
   ```elixir
   socket
   |> stream(:requests, requests)
   ```

2. **Template wrapping** - ALL LiveView templates must begin with `<Layouts.app flash={@flash}>`:
   ```heex
   <Layouts.app flash={@flash} current_scope={@current_scope}>
     <!-- content -->
   </Layouts.app>
   ```

3. **No inline scripts** - Write JavaScript in `assets/js/` and integrate via `app.js`

### Oban/Background Job Rules

1. **Use AshOban triggers** for automatic job scheduling based on resource state
2. **Manual triggers** via `change run_oban_trigger(:trigger_name)` when needed
3. **Queue selection:**
   - Use `batch_uploads` queue for file uploads (concurrency: 1)
   - Use `batch_processing` queue for downloads/processing (concurrency: 1)
   - Use `delivery` queue for webhooks/RabbitMQ (concurrency: 50)
   - Use `default` for everything else

### Testing Rules

1. **Use DataCase** for domain/business logic tests
2. **Always call `Ecto.Adapters.SQL.Sandbox.start_owner!`** in test setup
3. **Test via code interface** - use `Batcher.Batching.*` functions, not `Ash.*` directly

## Common Development Patterns

### Adding a New State Transition

1. Add transition to `state_machine` block:
   ```elixir
   transition :my_transition, from: :old_state, to: :new_state
   ```

2. Create the action:
   ```elixir
   update :my_transition do
     require_atomic? false
     change transition_state(:new_state)
     # Optional: trigger background job
     change run_oban_trigger(:my_job)
   end
   ```

3. Add to code interface in domain:
   ```elixir
   define :batch_my_transition, action: :my_transition, args: [:id]
   ```

### Adding Background Job Processing

1. Define trigger in resource's `oban` block:
   ```elixir
   trigger :my_job do
     action :my_job_action
     where expr(state == :target_state)
     queue :default
   end
   ```

2. Create custom action:
   ```elixir
   action :my_job_action, :struct do
     constraints instance_of: __MODULE__
     transaction? false
     run Batching.Actions.MyJobAction
   end
   ```

3. Implement action module in `lib/batcher/batching/actions/my_job_action.ex`

### Adding a New Validation

1. Create module in `lib/batcher/batching/validations/`:
   ```elixir
   defmodule Batcher.Batching.Validations.MyValidation do
     use Ash.Resource.Validation

     @impl true
     def validate(changeset, _opts, _context) do
       # Use Ash.Changeset.get_attribute(changeset, :field)
       # Return :ok or {:error, error}
     end
   end
   ```

2. Use in action:
   ```elixir
   create :create do
     validate Batching.Validations.MyValidation
   end
   ```

## Environment Variables

Required:
- `OPENAI_API_KEY` - OpenAI API key for batch processing

Optional:
- `SECRET_KEY_BASE` - Phoenix secret (auto-generated if not set)
- `DATABASE_PATH` - SQLite database path (default: `batcher_dev.db`)
- `PORT` - HTTP port (default: 4000)
- `PHX_HOST` - Application hostname (default: localhost)

## Docker Deployment

See `DOCKER.md` and `Dockerfile` for production deployment instructions.

**Key Points:**
- Database and batch files stored in `/data` volume
- Migrations run automatically on startup
- Health check monitors application status
