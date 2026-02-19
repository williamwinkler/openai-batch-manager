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
  attr :auto_dismiss, :boolean, default: true, doc: "auto dismiss after timeout"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)
    assigns = assign(assigns, :flash_key, to_string(assigns.kind))
    flash_hook = if assigns.auto_dismiss, do: "FlashAutoDismiss"

    dismiss_js =
      JS.push("lv:clear-flash", value: %{key: assigns.flash_key}) |> hide("##{assigns.id}")

    assigns =
      assigns
      |> assign(:dismiss_js, dismiss_js)
      |> assign(:flash_hook, flash_hook)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook={@flash_hook}
      data-flash-key={@flash_key}
      data-timeout-ms="10000"
      role="alert"
      class="w-full max-w-sm mb-2"
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
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          aria-label={gettext("close")}
          phx-click={@dismiss_js}
        >
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

  attr :row_navigate, :any,
    default: nil,
    doc: "function that returns a path to navigate to when clicking the row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  attr :class, :string, default: nil, doc: "additional classes for the table element"

  slot :col, required: true do
    attr :label, :string
    attr :width, :string, doc: "Tailwind width class for the column (e.g., 'w-32')"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      cond do
        is_struct(assigns.rows, Phoenix.LiveView.LiveStream) ->
          assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)

        assigns.row_navigate && is_nil(assigns.row_id) ->
          # Generate row IDs when row_navigate is used (hooks require IDs)
          assign(assigns, row_id: fn row -> "#{assigns.id}-row-#{row.id}" end)

        true ->
          assigns
      end

    ~H"""
    <table class={["table w-full table-fixed", @class]}>
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
          <th
            :if={@action != []}
            class="text-right font-semibold text-base-content/50 text-xs uppercase tracking-wider py-3 px-4 w-32"
          >
            {gettext("Actions")}
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          phx-hook={@row_navigate && "ClickableRow"}
          data-navigate-path={@row_navigate && @row_navigate.(@row_item.(row))}
          class={[
            "border-b border-base-300/50 hover:bg-base-200/50",
            @row_navigate && "cursor-pointer"
          ]}
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

  def icon(%{name: "batch-icon"} = assigns) do
    batch_icon(assigns)
  end

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a timeline status icon.

  ## Examples

      <.timeline_icon type={:completed} />
      <.timeline_icon type={:error} />
      <.timeline_icon type={:current} />
      <.timeline_icon type={:future} />
  """
  attr :type, :atom, required: true, values: [:completed, :error, :current, :future]

  def timeline_icon(%{type: :completed} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      class="w-5 h-5 text-primary"
    >
      <path
        fill-rule="evenodd"
        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  def timeline_icon(%{type: :error} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      class="w-5 h-5 text-error"
    >
      <path
        fill-rule="evenodd"
        d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  def timeline_icon(%{type: :current} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      class="w-5 h-5 text-primary animate-pulse"
    >
      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16z" clip-rule="evenodd" />
    </svg>
    """
  end

  def timeline_icon(%{type: :future} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      class="w-5 h-5 text-base-300"
    >
      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16z" clip-rule="evenodd" />
    </svg>
    """
  end

  attr :class, :string, default: "size-4"

  def batch_icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor">
      <path d="M3 7a4 4 0 0 1 4-4 1 1 0 0 1 0 2 2 2 0 0 0-2 2c0 .257.005.511.01.772v.032c.006.268.011.544.01.815-.004.535-.033 1.105-.16 1.652-.132.558-.372 1.114-.808 1.599a3.315 3.315 0 0 1-.13.137c.034.035.067.07.1.107.431.477.673 1.027.81 1.581.132.544.17 1.114.178 1.655.005.308 0 .657-.004.997-.003.227-.006.45-.006.653a2 2 0 0 0 2 2 1 1 0 1 1 0 2 4 4 0 0 1-4-4c0-.27.003-.51.007-.738.004-.303.008-.583.003-.88-.008-.49-.041-.884-.121-1.21-.078-.316-.192-.542-.351-.718-.158-.175-.41-.356-.847-.503A.995.995 0 0 1 1 12a.998.998 0 0 1 .691-.951c.457-.153.715-.34.875-.517.16-.178.272-.404.346-.718.077-.326.105-.719.108-1.207.001-.241-.004-.493-.009-.764v-.038A29.585 29.585 0 0 1 3 7Zm16.942 5.123c.039-.042.078-.083.118-.123a3.16 3.16 0 0 1-.117-.123c-.44-.482-.681-1.036-.811-1.594-.127-.545-.154-1.115-.155-1.65 0-.269.005-.544.011-.812v-.006C18.994 7.54 19 7.272 19 7a2 2 0 0 0-2-2 1 1 0 1 1 0-2 4 4 0 0 1 4 4c0 .296-.006.584-.012.854v.004c-.006.274-.011.527-.01.77 0 .491.027.88.101 1.2.072.308.183.528.341.702.16.174.421.362.889.519A.995.995 0 0 1 23 12a1.003 1.003 0 0 1-.692.951c-.468.157-.73.345-.889.52-.159.173-.269.393-.34.7-.075.321-.102.71-.103 1.201 0 .243.005.496.01.77l.001.004c.006.27.012.558.012.854a4 4 0 0 1-4 4 1 1 0 1 1 0-2 2 2 0 0 0 2-2c0-.272-.006-.54-.012-.814v-.007a34.216 34.216 0 0 1-.01-.811c0-.536.027-1.106.154-1.65.13-.56.37-1.113.81-1.595Z">
      </path>
      <path d="M9 11a1 1 0 1 0 0 2h6a1 1 0 1 0 0-2H9ZM8 8a1 1 0 0 1 1-1h6a1 1 0 1 1 0 2H9a1 1 0 0 1-1-1Zm1 7a1 1 0 1 0 0 2h6a1 1 0 1 0 0-2H9Z">
      </path>
    </svg>
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

      <.status_badge status={:delivered} />
      <.status_badge status={:failed} />
  """
  attr :status, :atom, required: true, doc: "the status to display"
  attr :type, :atom, default: :batch, doc: "the type of status (:batch or :request)"

  def status_badge(assigns) do
    {bg_class, text_class, dot_class} =
      case assigns.status do
        # Terminal/success states - green
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
        :partially_delivered -> {"bg-warning/15", "text-warning", "bg-warning"}
        # In progress states - blue
        :uploading -> {"bg-info/15", "text-info", "bg-info"}
        :uploaded -> {"bg-info/15", "text-info", "bg-info"}
        :waiting_for_capacity -> {"bg-info/15", "text-info", "bg-info"}
        :openai_processing -> {"bg-info/15", "text-info", "bg-info"}
        :downloading -> {"bg-info/15", "text-info", "bg-info"}
        :downloaded -> {"bg-info/15", "text-info", "bg-info"}
        :delivering -> {"bg-info/15", "text-info", "bg-info"}
        # Default/pending states - neutral gray
        _ -> {"bg-base-300", "text-base-content/70", "bg-base-content/50"}
      end

    {status_label, description} = get_status_info(assigns.status, assigns.type)

    assigns =
      assigns
      |> assign(:bg_class, bg_class)
      |> assign(:text_class, text_class)
      |> assign(:dot_class, dot_class)
      |> assign(:status_label, status_label)
      |> assign(:description, description)

    ~H"""
    <div class="tooltip tooltip-bottom inline-flex" data-tip={@description}>
      <span class={[
        "inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-medium",
        @bg_class,
        @text_class
      ]}>
        <span class={["w-1.5 h-1.5 rounded-full", @dot_class]}></span>
        {@status_label}
      </span>
    </div>
    """
  end

  defp get_status_info(status, :batch) do
    alias Batcher.Batching.Types.BatchStatus

    case BatchStatus.match(status) do
      {:ok, _} ->
        label = BatchStatus.label(status) || format_status(status)
        description = BatchStatus.description(status)
        {label, description}

      :error ->
        {format_status(status), nil}
    end
  end

  defp get_status_info(status, :request) do
    alias Batcher.Batching.Types.RequestStatus

    case RequestStatus.match(status) do
      {:ok, _} ->
        label = RequestStatus.label(status) || format_status(status)
        description = RequestStatus.description(status)
        {label, description}

      :error ->
        {format_status(status), nil}
    end
  end

  defp get_status_info(status, _type) do
    {format_status(status), nil}
  end

  defp format_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
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
          <.icon name="hero-globe-alt" class="w-3 h-3" /> Webhook
        <% else %>
          <img src="/images/rabbitmq.svg" class="w-3 h-3 inline-block" alt="RabbitMQ" /> RabbitMQ
        <% end %>
      </span>
    </div>
    """
  end

  @doc """
  Renders numbered pagination with ellipsis.

  ## Examples

      <.numbered_pagination
        page={@page}
        base_path="/batches"
        extra_params={[q: @query_text, sort_by: @sort_by]}
      />
  """
  attr :page, :map, required: true, doc: "the Ash page object with offset, limit, count, etc."
  attr :base_path, :string, required: true, doc: "the base URL path for pagination links"
  attr :extra_params, :list, default: [], doc: "additional query params to preserve"

  def numbered_pagination(assigns) do
    count = assigns.page.count || 0
    limit = assigns.page.limit || 20
    offset = assigns.page.offset || 0

    total_pages = if count > 0, do: ceil(count / limit), else: 1
    current_page = div(offset, limit) + 1

    # Generate page numbers with ellipsis
    page_numbers = generate_page_numbers(current_page, total_pages)

    assigns =
      assigns
      |> assign(:count, count)
      |> assign(:limit, limit)
      |> assign(:offset, offset)
      |> assign(:total_pages, total_pages)
      |> assign(:current_page, current_page)
      |> assign(:page_numbers, page_numbers)
      |> assign(:has_prev, current_page > 1)
      |> assign(:has_next, current_page < total_pages)
      |> assign(:start_item, if(count > 0, do: offset + 1, else: 0))
      |> assign(:end_item, min(offset + limit, count))

    ~H"""
    <div class="flex items-center justify-between py-3 px-4 bg-base-200/50 border border-base-300/50 rounded-box shrink-0">
      <div class="text-sm text-base-content/50">
        <%= if @count > 0 do %>
          {@start_item}-{@end_item} of {@count}
        <% else %>
          0 items
        <% end %>
      </div>
      <div class="join">
        <.link
          :if={@total_pages > 1}
          patch={build_pagination_url(@base_path, @extra_params, 0, @limit)}
          class={["join-item btn btn-sm", !@has_prev && "btn-disabled"]}
        >
          <.icon name="hero-chevron-double-left" class="w-4 h-4" />
        </.link>
        <.link
          :if={@total_pages > 1}
          patch={
            build_pagination_url(
              @base_path,
              @extra_params,
              max(0, (@current_page - 2) * @limit),
              @limit
            )
          }
          class={["join-item btn btn-sm", !@has_prev && "btn-disabled"]}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </.link>

        <%= for item <- @page_numbers do %>
          <%= case item do %>
            <% :ellipsis -> %>
              <span class="join-item btn btn-sm btn-disabled">...</span>
            <% page_num -> %>
              <.link
                patch={
                  build_pagination_url(@base_path, @extra_params, (page_num - 1) * @limit, @limit)
                }
                class={["join-item btn btn-sm", page_num == @current_page && "btn-primary"]}
              >
                {page_num}
              </.link>
          <% end %>
        <% end %>

        <.link
          :if={@total_pages > 1}
          patch={build_pagination_url(@base_path, @extra_params, @current_page * @limit, @limit)}
          class={["join-item btn btn-sm", !@has_next && "btn-disabled"]}
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </.link>
        <.link
          :if={@total_pages > 1}
          patch={build_pagination_url(@base_path, @extra_params, (@total_pages - 1) * @limit, @limit)}
          class={["join-item btn btn-sm", !@has_next && "btn-disabled"]}
        >
          <.icon name="hero-chevron-double-right" class="w-4 h-4" />
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  Renders pagination with async count states.
  """
  attr :page, :map, required: true
  attr :page_count_status, :atom, required: true
  attr :page_total_count, :any, default: nil
  attr :base_path, :string, required: true
  attr :extra_params, :list, default: []

  def async_count_pagination(assigns) do
    offset = assigns.page.offset || 0
    limit = assigns.page.limit || 20
    current_page = div(offset, limit) + 1
    has_prev = offset > 0
    has_next = length(assigns.page.results || []) >= limit

    assigns =
      assigns
      |> assign(:offset, offset)
      |> assign(:limit, limit)
      |> assign(:current_page, current_page)
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)

    ~H"""
    <%= if @page_count_status == :ready and is_integer(@page_total_count) do %>
      <.numbered_pagination
        page={Map.put(@page, :count, @page_total_count)}
        base_path={@base_path}
        extra_params={@extra_params}
      />
    <% else %>
      <div class="flex items-center justify-between py-3 px-4 bg-base-200/50 border border-base-300/50 rounded-box shrink-0">
        <div class="text-sm text-base-content/50">
          <%= if @page_count_status == :loading do %>
            Calculating...
          <% else %>
            Count unavailable
          <% end %>
        </div>
        <div class="join">
          <.link
            patch={build_pagination_url(@base_path, @extra_params, 0, @limit)}
            class={["join-item btn btn-sm", !@has_prev && "btn-disabled"]}
          >
            <.icon name="hero-chevron-double-left" class="w-4 h-4" />
          </.link>
          <.link
            patch={build_pagination_url(@base_path, @extra_params, max(0, @offset - @limit), @limit)}
            class={["join-item btn btn-sm", !@has_prev && "btn-disabled"]}
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" />
          </.link>
          <span class="join-item btn btn-sm btn-disabled">Page {@current_page}</span>
          <.link
            patch={build_pagination_url(@base_path, @extra_params, @offset + @limit, @limit)}
            class={["join-item btn btn-sm", !@has_next && "btn-disabled"]}
          >
            <.icon name="hero-chevron-right" class="w-4 h-4" />
          </.link>
        </div>
      </div>
    <% end %>
    """
  end

  # Generate page numbers with ellipsis for large page counts
  # Shows: 1 2 3 ... 8 or 1 ... 5 6 7 8 or 1 2 3 4 5 6 7 8
  defp generate_page_numbers(_current_page, total_pages) when total_pages <= 7 do
    Enum.to_list(1..total_pages)
  end

  defp generate_page_numbers(current_page, total_pages) do
    cond do
      # Near the beginning: 1 2 3 4 5 ... last
      current_page <= 4 ->
        Enum.to_list(1..5) ++ [:ellipsis, total_pages]

      # Near the end: 1 ... last-4 last-3 last-2 last-1 last
      current_page >= total_pages - 3 ->
        [1, :ellipsis] ++ Enum.to_list((total_pages - 4)..total_pages)

      # In the middle: 1 ... current-1 current current+1 ... last
      true ->
        [1, :ellipsis] ++
          Enum.to_list((current_page - 1)..(current_page + 1)) ++
          [:ellipsis, total_pages]
    end
  end

  defp build_pagination_url(base_path, extra_params, offset, limit) do
    params =
      extra_params
      |> Keyword.put(:offset, offset)
      |> Keyword.put(:limit, limit)
      |> Enum.filter(fn {_k, v} -> v != nil and v != "" end)

    "#{base_path}?#{URI.encode_query(params)}"
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

  @doc """
  Renders a delete batch button that conditionally shows based on batch state.

  ## Examples

      <.delete_batch_button batch_id={@batch.id} batch_state={@batch.state} />
      <.delete_batch_button batch_id={@batch.id} batch_state={@batch.state} class="btn-sm btn-soft btn-error" />
  """
  attr :batch_id, :integer, required: true, doc: "the batch ID to delete"
  attr :batch_state, :atom, required: true, doc: "the current state of the batch"

  attr :class, :string,
    default: "btn btn-sm btn-ghost text-error",
    doc: "additional CSS classes for the button"

  attr :confirm_message, :string,
    default:
      "Are you sure you want to delete this batch? This will delete the batch here, all requests in it, and the data on OpenAI's platform.",
    doc: "the confirmation message to display"

  attr :show_icon, :boolean, default: true, doc: "whether to show the trash icon"
  attr :label, :string, default: "Delete Batch", doc: "the button label text"
  attr :loading, :boolean, default: false, doc: "whether the button is in loading state"
  attr :loading_label, :string, default: "Deleting...", doc: "label shown while loading"
  attr :rest, :global

  def delete_batch_button(assigns) do
    deletable_states = [
      :done,
      :failed,
      :cancelled,
      :delivered,
      :partially_delivered,
      :delivery_failed
    ]

    should_show = assigns.batch_state in deletable_states

    assigns = assign(assigns, :should_show, should_show)

    ~H"""
    <button
      :if={@should_show}
      phx-click="delete_batch"
      phx-value-id={@batch_id}
      class={@class}
      data-confirm={@confirm_message}
      disabled={@loading}
      {@rest}
    >
      <%= if @loading do %>
        <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" />
        {@loading_label}
      <% else %>
        <%= if @show_icon do %>
          <.icon name="hero-trash" class="w-4 h-4" />
        <% end %>
        {@label}
      <% end %>
    </button>
    """
  end
end
