defmodule BatcherWeb.NavHooks do
  @moduledoc """
  LiveView hooks for navigation-related functionality.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :save_request_path, :handle_params, &save_request_path/3)}
  end

  defp save_request_path(_params, url, socket) do
    %{path: path} = URI.parse(url)
    {:cont, assign(socket, :current_path, path)}
  end
end
