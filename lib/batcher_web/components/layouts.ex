defmodule BatcherWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BatcherWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_path, :string, default: nil, doc: "the current request path for nav highlighting"

  attr :rabbitmq_connected, :any,
    default: nil,
    doc: "nil=not configured, true=connected, false=disconnected"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-100">
      <!-- Top Navbar -->
      <header class="bg-base-200 border-b border-base-300/50">
        <div class="flex items-center h-16 px-6">
          <div class="flex-1 flex items-center">
            <a href="/" class="flex items-center gap-1.5">
              <.icon name="batch-icon" class="w-7 h-7 shrink-0" />
              <span class="text-lg font-semibold tracking-tight hidden lg:inline">
                OpenAI Batch Manager
              </span>
            </a>
          </div>
          <nav class="flex items-center gap-1">
            <.nav_link
              href="/"
              icon="hero-home"
              label="Home"
              active={@current_path == "/"}
            />
            <.nav_link
              href="/batches"
              icon="batch-icon"
              label="Batches"
              active={@current_path && String.starts_with?(@current_path, "/batches")}
            />
            <.nav_link
              href="/requests"
              icon="hero-chat-bubble-bottom-center-text"
              label="Requests"
              active={@current_path && String.starts_with?(@current_path, "/requests")}
            />
            <.nav_link
              href="/settings"
              icon="hero-cog-6-tooth"
              label="Settings"
              active={@current_path && String.starts_with?(@current_path, "/settings")}
            />
          </nav>
          <div class="flex-1 flex items-center justify-end gap-3">
            <span class="text-xs text-base-content/20 font-mono select-all">
              v{Application.spec(:batcher, :vsn)}
            </span>
            <.rabbitmq_status rabbitmq_connected={@rabbitmq_connected} />
            <.theme_toggle />
          </div>
        </div>
      </header>
      
    <!-- Main Content -->
      <div class="flex-1 overflow-hidden">
        <main class="h-full overflow-auto p-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-md transition-colors",
        @active && "bg-primary/10 text-primary",
        !@active && "text-base-content/60 hover:bg-base-300/50 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="w-5 h-5" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="toast toast-top toast-end z-50">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # Remove app_with_sidebar as it's now merged into app

  @doc """
  Renders the RabbitMQ connection status indicator.
  Shows a green dot when connected, grey when disconnected or not configured.
  When configured, clicking opens a modal with connection details.
  """
  attr :rabbitmq_connected, :any,
    default: nil,
    doc: "nil=not configured, true=connected, false=disconnected"

  def rabbitmq_status(assigns) do
    publisher_config = Application.get_env(:batcher, :rabbitmq_publisher)
    consumer_config = Application.get_env(:batcher, :rabbitmq_input)
    configured? = publisher_config != nil || consumer_config != nil

    {connection_details, tooltip_text} =
      if configured? do
        # Get URL from publisher or consumer config
        url =
          (publisher_config && Keyword.get(publisher_config, :url)) ||
            (consumer_config && Keyword.get(consumer_config, :url)) ||
            "N/A"

        # Extract host from URL (e.g., "amqp://user:pass@host:5672" -> "host:5672")
        host_info =
          case URI.parse(url) do
            %URI{host: nil} -> url
            %URI{host: host, port: nil} -> host
            %URI{host: host, port: port} -> "#{host}:#{port}"
          end

        # Status row based on live connection state
        status_detail =
          case assigns.rabbitmq_connected do
            true -> %{label: "Status", value: "Connected"}
            false -> %{label: "Status", value: "Disconnected"}
            _ -> %{label: "Status", value: "Unknown"}
          end

        details = [status_detail, %{label: "Host", value: host_info}]

        # Add publisher status
        details =
          if publisher_config do
            details ++ [%{label: "Output delivery", value: "Enabled"}]
          else
            details ++
              [
                %{
                  label: "Output delivery",
                  value: "Disabled",
                  hint: "Set RABBITMQ_URL to enable"
                }
              ]
          end

        # Add consumer details if configured
        details =
          if consumer_config do
            queue = Keyword.get(consumer_config, :queue, "N/A")

            details = details ++ [%{label: "Input queue", value: queue}]

            details ++
              [
                %{
                  label: "Input mode",
                  value: "Queue"
                }
              ]
          else
            details ++
              [
                %{
                  label: "Input consumer",
                  value: "Disabled",
                  hint: "Set RABBITMQ_INPUT_QUEUE to enable"
                }
              ]
          end

        tooltip =
          if assigns.rabbitmq_connected == true,
            do: "RabbitMQ Connected",
            else: "RabbitMQ Disconnected"

        {details, tooltip}
      else
        {[], "RabbitMQ not configured"}
      end

    modal_id = "rabbitmq-status-modal"

    assigns =
      assigns
      |> assign(:configured?, configured?)
      |> assign(:tooltip_text, tooltip_text)
      |> assign(:connection_details, connection_details)
      |> assign(:modal_id, modal_id)

    ~H"""
    <div>
      <div
        :if={@configured?}
        class="tooltip tooltip-bottom"
        data-tip={@tooltip_text}
      >
        <button
          type="button"
          id="rabbitmq-status-btn"
          class="flex items-center gap-1.5 px-1.5 bg-base-300/50 rounded-lg h-7 cursor-pointer hover:bg-base-300 transition-colors"
          phx-hook="RabbitMQModal"
          data-modal-id={@modal_id}
        >
          <img src="/images/rabbitmq.svg" class="w-4 h-3.5" alt="RabbitMQ" />
          <span class={[
            "w-1.5 h-1.5 rounded-full",
            @rabbitmq_connected == true && "bg-success",
            @rabbitmq_connected != true && "bg-base-content/30"
          ]}>
          </span>
        </button>
      </div>
      <div
        :if={!@configured?}
        class="tooltip tooltip-bottom"
        data-tip={@tooltip_text}
      >
        <div class="flex items-center gap-1.5 px-1.5 bg-base-300/50 rounded-lg h-7">
          <img src="/images/rabbitmq.svg" class="w-4 h-3.5" alt="RabbitMQ" />
          <span class="w-1.5 h-1.5 rounded-full bg-base-content/30"></span>
        </div>
      </div>
      
    <!-- Modal -->
      <div
        id={@modal_id}
        class="hidden fixed inset-0 z-50 flex items-center justify-center p-4"
      >
        <%!-- Backdrop - only this closes the modal --%>
        <div class="absolute inset-0 bg-black/50" data-close-modal={@modal_id}></div>

        <%!-- Modal Content - clicks here don't close --%>
        <div class="relative bg-base-100 rounded-lg shadow-xl w-full max-w-2xl max-h-[90vh] flex flex-col">
          <%!-- Header --%>
          <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between shrink-0">
            <h3 class="text-lg font-semibold">RabbitMQ Connection Details</h3>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-circle"
              data-close-modal={@modal_id}
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <%!-- Body --%>
          <div class="p-6 overflow-auto flex-1">
            <div class="space-y-4">
              <div :for={detail <- @connection_details} class="flex flex-col gap-1">
                <span class="text-sm font-semibold text-base-content/70">{detail.label}</span>
                <span class={[
                  "text-base font-mono",
                  detail[:hint] && "text-base-content/50",
                  !detail[:hint] && "text-base-content"
                ]}>
                  {detail.value}
                </span>
                <span :if={detail[:hint]} class="text-xs text-base-content/50 italic">
                  {detail.hint}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="flex items-center gap-0.5 px-1 bg-base-300/50 rounded-lg h-7"
      phx-hook="ThemeToggle"
      id="theme-toggle"
    >
      <button
        class="p-1 rounded hover:bg-base-200 transition-colors theme-btn cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        data-theme-value="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop" class="size-3.5 text-base-content/60" />
      </button>
      <button
        class="p-1 rounded hover:bg-base-200 transition-colors theme-btn cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        data-theme-value="light"
        title="Light theme"
      >
        <.icon name="hero-sun" class="size-3.5 text-base-content/60 cursor-pointer" />
      </button>
      <button
        class="p-1 rounded hover:bg-base-200 transition-colors theme-btn cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        data-theme-value="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon" class="size-3.5 text-base-content/60 cursor-pointer" />
      </button>
    </div>
    """
  end
end
