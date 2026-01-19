defmodule BatcherWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: BatcherWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert shadow-lg border max-w-sm",
        @kind == :info && "bg-base-200 border-base-300 text-base-content",
        @kind == :error && "bg-error/10 border-error/20 text-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-check-circle" class="size-5 shrink-0 text-success" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div class="flex-1 text-sm">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <button type="button" class="btn btn-ghost btn-xs" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :string
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :width, :string, doc: "Tailwind width class for the column (e.g., 'w-32')"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table w-full table-fixed">
      <thead>
        <tr class="border-b border-base-300">
          <th
            :for={col <- @col}
            class={[
              "text-left font-semibold text-base-content/50 text-xs uppercase tracking-wider py-3 px-4",
              col[:width]
            ]}
          >
            {col[:label]}
          </th>
          <th :if={@action != []} class="text-right py-3 px-4 w-28">
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          class="border-b border-base-300/50 hover:bg-base-200/50"
        >
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={["py-3 px-4", @row_click && "hover:cursor-pointer"]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="py-3 px-2 text-right">
            <div class="flex justify-end items-center">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(BatcherWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(BatcherWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a status badge matching OpenAI platform style.

  ## Examples

      <.status_badge status={:done} />
      <.status_badge status={:failed} />
  """
  attr :status, :atom, required: true, doc: "the status to display"

  def status_badge(assigns) do
    {bg_class, text_class, dot_class} =
      case assigns.status do
        # Terminal/success states - green
        :done -> {"bg-success/15", "text-success", "bg-success"}
        :delivered -> {"bg-success/15", "text-success", "bg-success"}
        :openai_completed -> {"bg-success/15", "text-success", "bg-success"}
        :ready_to_deliver -> {"bg-success/15", "text-success", "bg-success"}
        :openai_processed -> {"bg-success/15", "text-success", "bg-success"}
        # Error states - red
        :failed -> {"bg-error/15", "text-error", "bg-error"}
        :delivery_failed -> {"bg-error/15", "text-error", "bg-error"}
        # Warning states - orange/yellow
        :cancelled -> {"bg-warning/15", "text-warning", "bg-warning"}
        :expired -> {"bg-warning/15", "text-warning", "bg-warning"}
        # In progress states - blue
        :uploading -> {"bg-info/15", "text-info", "bg-info"}
        :uploaded -> {"bg-info/15", "text-info", "bg-info"}
        :openai_processing -> {"bg-info/15", "text-info", "bg-info"}
        :downloading -> {"bg-info/15", "text-info", "bg-info"}
        :downloaded -> {"bg-info/15", "text-info", "bg-info"}
        :delivering -> {"bg-info/15", "text-info", "bg-info"}
        # Default/pending states - neutral gray
        _ -> {"bg-base-300", "text-base-content/70", "bg-base-content/50"}
      end

    status_label =
      assigns.status
      |> to_string()
      |> String.replace("_", " ")

    assigns =
      assigns
      |> assign(:bg_class, bg_class)
      |> assign(:text_class, text_class)
      |> assign(:dot_class, dot_class)
      |> assign(:status_label, status_label)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-medium",
      @bg_class,
      @text_class
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", @dot_class]}></span>
      {@status_label}
    </span>
    """
  end

  @doc """
  Renders pagination controls.

  ## Examples

      <.pagination_controls
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
        phx_click="paginate"
      />
  """
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total_count, :integer, required: true
  attr :phx_click, :string, default: "paginate"
  attr :query_text, :string, default: ""
  attr :sort_by, :string, default: "-created_at"

  def pagination_controls(assigns) do
    total_pages = ceil(assigns.total_count / assigns.per_page)
    has_prev = assigns.page > 1
    has_next = assigns.page < total_pages

    assigns = assign(assigns, :total_pages, total_pages)
    assigns = assign(assigns, :has_prev, has_prev)
    assigns = assign(assigns, :has_next, has_next)

    ~H"""
    <div class="flex items-center justify-between pt-4">
      <div class="text-sm text-base-content/50">
        {(@page - 1) * @per_page + 1}-{min(@page * @per_page, @total_count)} of {@total_count}
      </div>
      <div class="flex items-center gap-1">
        <button
          :if={@has_prev}
          phx-click={@phx_click}
          phx-value-page={@page - 1}
          class="btn btn-sm btn-ghost text-base-content/70"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </button>
        <span class="px-3 text-sm text-base-content/60">
          {@page} / {@total_pages}
        </span>
        <button
          :if={@has_next}
          phx-click={@phx_click}
          phx-value-page={@page + 1}
          class="btn btn-sm btn-ghost text-base-content/70"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Displays delivery configuration in a formatted way.

  ## Examples

      <.delivery_config_display config={@request.delivery_config} />
  """
  attr :config, :map, required: true

  def delivery_config_display(assigns) do
    delivery_type = Map.get(assigns.config, "type") || Map.get(assigns.config, :type)

    assigns = assign(assigns, :delivery_type, delivery_type)

    ~H"""
    <div class="text-xs">
      <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded bg-base-300/50 text-base-content/70 font-medium">
        <%= if @delivery_type == "webhook" do %>
          <.icon name="hero-globe-alt" class="w-3 h-3" /> webhook
        <% else %>
          <.icon name="hero-arrow-path" class="w-3 h-3" /> rabbitmq
        <% end %>
      </span>
    </div>
    """
  end

  @doc """
  Renders breadcrumb navigation.

  ## Examples

      <.breadcrumb items={[{"Batches", "/"}, {"Batch 123", "/batches/123"}]} />
  """
  attr :items, :list, required: true, doc: "list of {label, path} tuples"

  def breadcrumb(assigns) do
    ~H"""
    <nav class="flex items-center gap-1.5 text-sm mb-6">
      <%= for {item, index} <- Enum.with_index(@items) do %>
        <%= if index > 0 do %>
          <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/30" />
        <% end %>
        <% {label, path} = item %>
        <%= if index == length(@items) - 1 do %>
          <span class="text-base-content/60">{label}</span>
        <% else %>
          <.link navigate={path} class="text-base-content/60 hover:text-base-content">
            {label}
          </.link>
        <% end %>
      <% end %>
    </nav>
    """
  end
end
