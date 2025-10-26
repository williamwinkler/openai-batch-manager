# Test Guide for LLM Batch Manager

## Test Folder Structure

```
test/
├── batcher/
│   ├── batching/                    # Domain-level tests
│   │   ├── batch_test.exs           # Batch resource tests
│   │   ├── prompt_test.exs          # Prompt resource tests
│   │   └── validations/             # Validation-specific tests
│   │       ├── validate_delivery_config_test.exs
│   │       └── validate_prompt_matches_batch_test.exs
│   └── batching_test.exs            # Domain API/code interface tests (future)
├── batcher_web/                     # Web layer tests (future)
│   ├── controllers/
│   └── live/
├── support/
│   ├── data_case.ex                 # For domain/Ash tests
│   ├── conn_case.ex                 # For web tests
│   └── fixtures/
│       └── batching_fixtures.ex     # Test data helpers
└── test_helper.exs
```

## Test Organization Principles

### 1. Use DataCase for Domain Tests

All tests for Ash resources, validations, and business logic should use `DataCase`:

```elixir
defmodule Batcher.Batching.BatchTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching
  import Batcher.BatchingFixtures

  # tests...
end
```

### 2. Use Fixtures for Test Data

The `Batcher.BatchingFixtures` module provides helpers to create test data:

```elixir
# Create a batch with defaults
batch = batch_fixture()

# Create with custom attributes
batch = batch_fixture(provider: :openai, model: "gpt-4o")

# Create in a specific state
batch = batch_fixture(state: :ready_for_upload)

# Create a prompt
prompt = prompt_fixture(batch: batch)

# Shorthand for webhook/rabbitmq prompts
prompt = webhook_prompt_fixture()
prompt = rabbitmq_prompt_fixture()

# Create batch with multiple prompts
{batch, prompts} = batch_with_prompts_fixture(prompt_count: 3)
```

### 3. Test Through Code Interface

**Always** use the domain's code interface functions defined in `Batcher.Batching`:

```elixir
# CORRECT
{:ok, batch} = Batching.create_batch(:openai, "gpt-4")
{:ok, batch} = Batching.batch_mark_ready(batch)

# INCORRECT - Don't call Ash.create! directly
Ash.create!(Batcher.Batching.Batch, %{provider: :openai})
```

### 4. Available Code Interface Functions

#### Batch Functions
- `create_batch(provider, model)`
- `get_batches()` - List all batches
- `get_batch_by_id(id, opts \\ [])` - Get single batch
- `destroy_batch(batch)`

#### Batch State Transitions
- `batch_mark_ready(batch)`
- `batch_begin_upload(batch)`
- `batch_mark_validating(batch, %{provider_batch_id: id})` - Requires provider_batch_id as map param
- `batch_mark_in_progress(batch)`
- `batch_mark_finalizing(batch)`
- `batch_begin_download(batch)`
- `batch_mark_completed(batch)`
- `batch_mark_failed(batch, error_msg \\ nil)`
- `batch_mark_expired(batch)`
- `batch_cancel(batch)`

#### Prompt Functions
- `create_prompt(%{batch_id: id, custom_id: id, delivery_type: type, provider: p, model: m, ...})` - Pass all params in a map
- `get_prompts()` - Returns `{:ok, list}` not just `list`
- `get_prompt_by_id(id, opts \\ [])` - Returns `{:ok, prompt}` not just `prompt`

#### Prompt State Transitions
- `prompt_begin_processing(prompt)`
- `prompt_complete_processing(prompt)` - Transitions to `:processed`
- `prompt_begin_delivery(prompt)`
- `prompt_complete_delivery(prompt)` - Transitions to `:delivered`
- `prompt_mark_failed(prompt, error_msg \\ nil)`
- `prompt_mark_expired(prompt)`
- `prompt_cancel(prompt)`

### 5. Loading Relationships

To load relationships, pass `load: [...]` option. Remember that read functions return `{:ok, result}` tuples:

```elixir
# Load transitions
{:ok, batch} = Batching.get_batch_by_id(id, load: [:transitions])

# Load prompts and transitions
{:ok, batch} = Batching.get_batch_by_id(id, load: [:prompts, :transitions])

# Load batch from prompt
{:ok, prompt} = Batching.get_prompt_by_id(id, load: [:batch])

# List functions also return tuples
{:ok, batches} = Batching.get_batches()
{:ok, prompts} = Batching.get_prompts()
```

### 6. Handling Errors

Test both success and error cases:

```elixir
# Success case
{:ok, batch} = Batching.create_batch(:openai, "gpt-4")
assert batch.state == :draft

# Error case - invalid provider
{:error, error} = Batching.create_batch(:invalid_provider, "model")
assert error.errors != []

# Check error messages
error_messages = Enum.map(error.errors, & &1.message)
assert Enum.any?(error_messages, &String.contains?(&1, "provider"))
```

### 7. Important API Notes

**Provider Support**: Only `:openai` is currently supported. Don't test with `:anthropic` or other providers.

**State Machine**: The `batch_mark_validating` action requires a `provider_batch_id` parameter as a map: `batch_mark_validating(batch, %{provider_batch_id: "id"})`

**Return Values**:
- Read functions (`get_batch_by_id`, `get_batches`, `get_prompt_by_id`, etc.) return `{:ok, result}` tuples
- Create functions return `{:ok, resource}` tuples
- Update/transition functions return `{:ok, resource}` tuples
- `destroy_batch` returns `:ok` (not `{:ok, batch}`)

**Creating Prompts**: The `create_prompt` function accepts a single map with all parameters (both attributes and arguments):
```elixir
{:ok, prompt} = Batching.create_prompt(%{
  batch_id: batch.id,
  custom_id: "prompt-1",
  delivery_type: :webhook,
  webhook_url: "https://example.com/webhook",
  provider: batch.provider,  # Must match batch
  model: batch.model          # Must match batch
})
```

**Fixtures Accept Maps or Keyword Lists**: All fixture functions are designed to accept either maps or keyword lists for convenience.

## Test Examples

### Basic Resource Test

```elixir
test "creates batch with valid attributes" do
  {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

  assert batch.provider == :openai
  assert batch.model == "gpt-4"
  assert batch.state == :draft
end
```

### State Transition Test

```elixir
test "transitions batch from draft to ready_for_upload" do
  {:ok, batch} = Batching.create_batch(:openai, "gpt-4")

  {:ok, updated_batch} = Batching.batch_mark_ready(batch)

  assert updated_batch.state == :ready_for_upload
end
```

### Validation Test

```elixir
test "fails when webhook_url is missing" do
  batch = batch_fixture()

  {:error, error} = Batching.create_prompt(%{
    batch_id: batch.id,
    custom_id: "test",
    delivery_type: :webhook,
    provider: batch.provider,
    model: batch.model
  })

  assert error.errors != []
  error_messages = Enum.map(error.errors, & &1.message)
  assert Enum.any?(error_messages, &String.contains?(&1, "webhook_url"))
end
```

### Using Fixtures Test

```elixir
test "uses fixtures effectively" do
  # Create batch in specific state
  batch = batch_fixture(state: :ready_for_upload)
  assert batch.state == :ready_for_upload

  # Create prompts easily
  prompt1 = webhook_prompt_fixture(batch: batch)
  prompt2 = rabbitmq_prompt_fixture(batch: batch)

  assert prompt1.delivery_type == :webhook
  assert prompt2.delivery_type == :rabbitmq
end
```

## Running Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/batcher/batching/batch_test.exs

# Run specific test by line number
mix test test/batcher/batching/batch_test.exs:42

# Run all previously failed tests
mix test --failed

# Run tests with detailed output
mix test --trace
```

## Best Practices

1. **Use `async: true` with SQLite caveats** - Most domain tests can run asynchronously, but be aware:
   - SQLite has limited concurrent write capability
   - Tests are configured with WAL mode and busy timeout for better concurrency
   - If you experience intermittent "Database busy" errors, consider reducing parallelism or using `async: false`
   - The test database uses a connection pool of 10 with a 5-second busy timeout
2. **Test happy and unhappy paths** - Cover both success and failure scenarios
3. **Test state machine transitions** - Verify both valid and invalid transitions
4. **Test validations** - Ensure business rules are enforced
5. **Use fixtures** - Keep tests DRY and maintainable
6. **Test relationships** - Verify data integrity across resources
7. **Focus on behavior** - Test what the code does, not how it does it
8. **Keep tests isolated** - Each test should set up its own data
9. **Use descriptive test names** - Make failures easy to understand
10. **Check error messages** - Don't just assert errors exist, verify they're correct
