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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-100">
      <!-- Top Navbar -->
      <header class="bg-base-200 border-b border-base-300/50">
        <div class="flex items-center justify-between h-16 px-6">
          <div class="flex items-center gap-8">
            <a href="/" class="flex items-center gap-2.5">
              <span class="text-lg font-semibold tracking-tight">OpenAI Batch Manager</span>
            </a>
            <nav class="flex items-center gap-1">
              <.nav_link
                href="/"
                icon="hero-chart-bar-square"
                label="Dashboard"
                active={@current_path == "/"}
              />
              <.nav_link
                href="/batches"
                icon="hero-rectangle-stack"
                label="Batches"
                active={@current_path && String.starts_with?(@current_path, "/batches")}
              />
              <.nav_link
                href="/requests"
                icon="hero-chat-bubble-bottom-center-text"
                label="Requests"
                active={@current_path && String.starts_with?(@current_path, "/requests")}
              />
            </nav>
          </div>
          <div class="flex items-center">
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
        @active && "bg-primary/10 text-primary font-medium",
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
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
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
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="flex items-center justify-center gap-1 p-1 bg-base-300/50 rounded-lg"
      phx-hook="ThemeToggle"
      id="theme-toggle"
    >
      <button
        class="p-1.5 rounded hover:bg-base-200 transition-colors theme-btn"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        data-theme-value="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop" class="size-4 text-base-content/60" />
      </button>
      <button
        class="p-1.5 rounded hover:bg-base-200 transition-colors theme-btn"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        data-theme-value="light"
        title="Light theme"
      >
        <.icon name="hero-sun" class="size-4 text-base-content/60" />
      </button>
      <button
        class="p-1.5 rounded hover:bg-base-200 transition-colors theme-btn"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        data-theme-value="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon" class="size-4 text-base-content/60" />
      </button>
    </div>
    """
  end
end
