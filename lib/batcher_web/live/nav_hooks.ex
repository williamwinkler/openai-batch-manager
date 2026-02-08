defmodule BatcherWeb.NavHooks do
  @moduledoc """
  LiveView hooks for navigation-related functionality.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:rabbitmq_connected, compute_rabbitmq_status())
      |> attach_hook(:save_request_path, :handle_params, &save_request_path/3)
      |> attach_hook(:rabbitmq_status_handler, :handle_info, &handle_rabbitmq_status/2)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Batcher.PubSub, "rabbitmq:status")
    end

    {:cont, socket}
  end

  defp save_request_path(_params, url, socket) do
    %{path: path} = URI.parse(url)
    {:cont, assign(socket, :current_path, path)}
  end

  defp handle_rabbitmq_status({:rabbitmq_status, _payload}, socket) do
    {:halt, assign(socket, :rabbitmq_connected, compute_rabbitmq_status())}
  end

  defp handle_rabbitmq_status(_message, socket) do
    {:cont, socket}
  end

  defp compute_rabbitmq_status do
    publisher_configured = Application.get_env(:batcher, :rabbitmq_publisher) != nil
    consumer_configured = Application.get_env(:batcher, :rabbitmq_input) != nil

    cond do
      !publisher_configured and !consumer_configured ->
        # Not configured at all
        nil

      true ->
        # Check actual connection status of configured processes
        publisher_ok = !publisher_configured or Batcher.RabbitMQ.Publisher.connected?()
        consumer_ok = !consumer_configured or Batcher.RabbitMQ.Consumer.connected?()
        publisher_ok and consumer_ok
    end
  end
end
