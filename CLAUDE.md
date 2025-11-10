# OpenAI Batch Manager

This is a **Phoenix 1.8.1** web application built with the **Ash Framework** for managing batching of LLM prompts for processing by providers like OpenAI. The application provides state machine-based workflow management with audit trails for both batches and individual prompts.

**Tech Stack:**
- Phoenix 1.8.1 + Ash Framework 3.0 (domain-driven development)
- Database: SQLite with AshSqlite adapter
- Job Queue: Oban 2.0 for background processing
- State Management: AshStateMachine extension
- Admin Dashboard: AshAdmin (dev only)
- Styling: Tailwind v4 + daisyUI

## Project Overview

The application manages two primary resources:
- **Batches** - Collections of prompts with 11-state workflow (draft → upload → processing → download → completed/failed/etc)
- **Prompts** - Individual LLM prompts with 8-state workflow (pending → processing → delivery → delivered/failed/etc)

Both resources use state machines with automatic audit trails tracking every state transition.

## Project Guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- **Never** create traditional Phoenix Contexts - this app uses Ash Framework domains instead (see Ash Framework guidelines below)

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/batcher_web";

- **Always use and maintain this import syntax** in the [app.css](assets/css/app.css) file
- **Never** use `@apply` when writing raw css
- This project includes **daisyUI** for component library - you can use daisyUI components alongside custom Tailwind classes
- **Heroicons** are available via the `<.icon name="hero-x-mark" />` component from [core_components.ex](lib/batcher_web/components/core_components.ex)
- The app supports **light and dark themes** - use daisyUI theme classes and test both themes
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->


<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Never** write embedded `<script>` tags in HEEx. Instead always write your scripts and hooks in the `assets/js` directory and integrate them with the `assets/js/app.js` file

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
        socket
        |> assign(:messages_empty?, messages == [])
        # reset the stream with the new messages
        |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

<!-- phoenix:liveview-end -->

## Ash Framework Guidelines

This project uses **Ash Framework 3.0** for domain-driven development. Ash replaces traditional Phoenix Contexts with a powerful resource-based architecture.

### Core Concepts

- **Resources** - Domain entities (like `Batcher.Batching.Batch` and `Batcher.Batching.Prompt`) that define attributes, relationships, actions, and validations
- **Domains** - Collections of related resources (like `Batcher.Batching` domain) that define the API surface
- **Actions** - Named operations on resources (`:create`, `:read`, `:update`, `:destroy`, or custom actions)
- **Code Interface** - Functions defined in the domain that provide a clean API for calling actions

### Working with Ash Resources

**Always** use the domain's code interface functions instead of calling Ash APIs directly:

```elixir
# CORRECT - Use code interface defined in Batcher.Batching domain
Batcher.Batching.create_batch("gpt-4", "/v1/responses")
Batcher.Batching.batch_mark_ready(batch)

# INCORRECT - Don't call Ash.create! directly
Ash.create!(Batcher.Batching.Batch, %{model: "gpt-4", endpoint: "/v1/responses"})
```

### Defining Code Interfaces

In the domain module ([lib/batcher/batching.ex](lib/batcher/batching.ex)), use `define` to expose actions:

```elixir
code_interface do
  define :create_batch, action: :create, args: [:model, :endpoint]
  define :batch_mark_ready, action: :mark_ready, args: [:id]
end
```

### Custom Actions in Resources

Define custom actions in resource modules for business logic:

```elixir
actions do
  # Standard CRUD
  defaults [:read]

  create :create do
    accept [:model, :endpoint]
  end

  # Custom state transition action
  update :mark_ready do
    # State machine transition
    change transition_state(:ready_for_upload)
  end
end
```

### SQLite-Specific Requirements

**CRITICAL**: All state machine actions in this project **must** include `require_atomic? false`:

```elixir
update :mark_ready do
  require_atomic? false  # REQUIRED for SQLite
  change transition_state(:ready_for_upload)
end
```

Without this, state transitions will fail with SQLite. This is a known limitation of AshSqlite.

### Relationships

Define relationships in resources:

```elixir
relationships do
  belongs_to :batch, Batcher.Batching.Batch
  has_many :prompts, Batcher.Batching.Prompt
  has_many :transitions, Batcher.Batching.BatchTransition
end
```

**Always** load relationships explicitly when needed:

```elixir
# Load relationships
batch = Batcher.Batching.get_batch!(id, load: [:prompts, :transitions])

# Access loaded relationships
batch.prompts
```

### Custom Validations

Create validation modules in [lib/batcher/batching/validations/](lib/batcher/batching/validations/):

```elixir
defmodule Batcher.Batching.Validations.ValidateDeliveryConfig do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # Validation logic using Ash.Changeset functions
    delivery_type = Ash.Changeset.get_attribute(changeset, :delivery_type)
    # ... add errors with Ash.Changeset.add_error/2
  end
end
```

Use validations in actions:

```elixir
create :create do
  validate Batcher.Batching.Validations.ValidateDeliveryConfig
end
```

### Accessing Attributes in Changes/Validations

**Never** use map syntax on changesets or resources - use Ash functions:

```elixir
# CORRECT
delivery_type = Ash.Changeset.get_attribute(changeset, :delivery_type)
webhook_url = Ash.Changeset.get_attribute(changeset, :webhook_url)

# INCORRECT - will fail
delivery_type = changeset[:delivery_type]
webhook_url = changeset.attributes[:webhook_url]
```

### Development Tools

The project includes **AshAdmin** dashboard at `/admin` (dev environment only) for exploring resources, viewing data, and testing actions interactively.

## State Machine Guidelines

This project uses **AshStateMachine** extension for managing batch and prompt workflows.

### State Machine Basics

Resources using state machines:
- [Batch](lib/batcher/batching/batch.ex) - 11 states (draft → ready_for_upload → uploading → validating → in_progress → finalizing → downloading → completed/failed/expired/cancelled)
- [Prompt](lib/batcher/batching/prompt.ex) - 8 states (pending → processing → processed → delivering → delivered/failed/expired/cancelled)

### Defining State Machines

In resource modules:

```elixir
use Ash.Resource,
  domain: Batcher.Batching,
  data_layer: AshSqlite.DataLayer,
  extensions: [AshStateMachine]  # Add extension

attributes do
  # State attribute
  attribute :state, :atom do
    allow_nil? false
    default :draft
    constraints [one_of: [:draft, :ready_for_upload, ...]]
  end
end

state_machine do
  initial_states [:draft]
  default_initial_state :draft

  transitions do
    transition :mark_ready, from: :draft, to: :ready_for_upload
    transition :begin_upload, from: :ready_for_upload, to: :uploading
    # ... more transitions
  end
end
```

### Creating Transition Actions

Every state transition needs a corresponding action:

```elixir
actions do
  update :mark_ready do
    require_atomic? false  # REQUIRED for SQLite
    accept []  # Transitions typically don't accept attributes

    # Trigger the state machine transition
    change transition_state(:ready_for_upload)
  end
end
```

### State Transition Constraints

Add validation logic to transition actions:

```elixir
update :mark_ready do
  require_atomic? false

  # Ensure required fields are present before allowing transition
  validate present([:provider, :model], at_least: 2)

  change transition_state(:ready_for_upload)
end
```

### Calling State Transitions

Use the code interface functions defined in the domain:

```elixir
# Create batch in initial state
{:ok, batch} = Batcher.Batching.create_batch(:openai, "gpt-4")
# batch.state == :draft

# Transition to next state
{:ok, batch} = Batcher.Batching.batch_mark_ready(batch)
# batch.state == :ready_for_upload
```

## Audit Trail Pattern

This project automatically records **every state transition** for both batches and prompts using a custom change module.

### How Audit Trails Work

The [CreateTransition](lib/batcher/batching/changes/create_transition.ex) change hooks into the after_action lifecycle and creates a transition record whenever a resource's state changes.

### Transition Resources

- `BatchTransition` - Records batch state changes (batch_id, from, to, transitioned_at)
- `PromptTransition` - Records prompt state changes (prompt_id, from, to, transitioned_at)

### Using CreateTransition

Add the change to every state transition action:

```elixir
update :mark_ready do
  require_atomic? false
  change transition_state(:ready_for_upload)

  # Automatically create audit trail entry
  change Batcher.Batching.Changes.CreateTransition
end
```

### Initial State Recording

For create actions, the change records the initial state with `from: nil`:

```elixir
create :create do
  accept [:provider, :model]

  # Records transition from nil → :draft
  change Batcher.Batching.Changes.CreateTransition
end
```

### Accessing Audit History

Load transitions to view the complete state history:

```elixir
batch = Batcher.Batching.get_batch!(id, load: [:transitions])

Enum.each(batch.transitions, fn t ->
  IO.puts("#{t.from} → #{t.to} at #{t.transitioned_at}")
end)
```

**Important**: Every action that creates or modifies state **must** include the `CreateTransition` change to maintain audit trail integrity.

## Domain-Specific Business Rules

### Batch-Prompt Consistency

Prompts must match their parent batch's configuration:

- **Model consistency** - Prompt's model must match batch's model
- **Endpoint consistency** - Prompt's endpoint must match batch's endpoint

Batches are created for a specific model/endpoint combination, and all prompts in that batch must use the same values.

```elixir
# Prompts are automatically assigned to batches with matching model/endpoint
# by the BatchBuilder GenServer
```

### Delivery Configuration Validation

Prompts have two delivery mechanisms: **webhook** or **rabbitmq**.

The [ValidateDeliveryConfig](lib/batcher/batching/validations/validate_delivery_config.ex) validation enforces:

**For webhook delivery:**
- `webhook_url` must be present and valid HTTP/HTTPS URL
- `rabbitmq_queue` must be nil

**For RabbitMQ delivery:**
- `rabbitmq_queue` must be present and non-empty
- `webhook_url` must be nil

```elixir
# Valid webhook configuration
{:ok, prompt} = Batcher.Batching.create_prompt(batch,
  custom_id: "p1",
  delivery_type: :webhook,
  webhook_url: "https://example.com/webhook"
)

# Valid RabbitMQ configuration
{:ok, prompt} = Batcher.Batching.create_prompt(batch,
  custom_id: "p2",
  delivery_type: :rabbitmq,
  rabbitmq_queue: "results_queue"
)

# Invalid - missing webhook_url
{:error, _} = Batcher.Batching.create_prompt(batch,
  custom_id: "p3",
  delivery_type: :webhook
)
```

### Custom ID Uniqueness

Each prompt must have a unique `custom_id` within its batch (enforced at database level).

## Oban Integration

The project uses **Oban 2.0** with **AshOban** integration for background job processing.

### Configuration

Oban is configured in [config/config.exs](config/config.exs) with:
- SQLite engine (`:lite`)
- Default queue with max 10 concurrent jobs
- Cron plugin for scheduled tasks
- PG notifier (works with SQLite via polling)

### AshOban Actions

You can define Oban-powered actions in Ash resources for async processing:

```elixir
actions do
  update :process_async do
    # AshOban will automatically enqueue this as a background job
  end
end
```

### Monitoring

Access the Oban dashboard at `/oban` (dev environment) to monitor jobs, queues, and failures.

## Testing Guidelines

### Test Structure

- **DataCase** ([test/support/data_case.ex](test/support/data_case.ex)) - For domain/business logic tests
- **ConnCase** ([test/support/conn_case.ex](test/support/conn_case.ex)) - For controller/web tests

### SQLite Sandbox

Tests use Ecto SQL Sandbox for isolation:

```elixir
setup tags do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Batcher.Repo, shared: not tags[:async])
  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  :ok
end
```

### Testing Ash Resources

Use the code interface in tests:

```elixir
test "creates batch with valid attributes" do
  {:ok, batch} = Batcher.Batching.create_batch("gpt-4", "/v1/responses")

  assert batch.model == "gpt-4"
  assert batch.endpoint == "/v1/responses"
  assert batch.state == :draft
end

test "validates state transitions" do
  {:ok, batch} = Batcher.Batching.create_batch("gpt-4", "/v1/responses")

  # Should succeed
  {:ok, batch} = Batcher.Batching.batch_mark_ready(batch)
  assert batch.state == :ready_for_upload

  # Should fail - invalid transition
  {:error, _} = Batcher.Batching.batch_begin_finalizing(batch)
end
```

### Testing Validations

Test validation rules by attempting invalid operations:

```elixir
test "validates delivery config" do
  # Prompts are validated when sent via the API
  # The validation checks for required delivery configuration
end
```

## Database Migrations

The project uses **AshSqlite** which auto-generates migrations.

### Initial Migration

The initial setup migration is at [priv/repo/migrations/20251026064846_initial_setup.exs](priv/repo/migrations/20251026064846_initial_setup.exs)

It creates:
- `batches` table with state, model, and endpoint fields
- `prompts` table with delivery config and foreign key to batches
- `batch_transitions` and `prompt_transitions` audit tables
- Indexes for foreign keys and state lookups

### Running Migrations

Migrations run automatically on application start via the `Batcher.Release` migrator in the supervision tree.

Manual migration commands:
```bash
mix ecto.migrate
mix ecto.rollback
```

### Generating Migrations

When you modify Ash resources, generate migrations with:

```bash
mix ash.codegen initial_migration
```

This will create migration files based on resource schema changes.
