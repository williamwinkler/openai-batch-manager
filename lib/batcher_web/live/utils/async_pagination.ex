defmodule BatcherWeb.Live.Utils.AsyncPagination do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  require Phoenix.LiveView

  def init(socket) do
    socket
    |> assign(:page_count_status, :loading)
    |> assign(:page_total_count, nil)
    |> assign(:count_request_key, nil)
    |> assign(:count_last_success_at_ms, nil)
  end

  def schedule_count(socket, count_request_key, count_fun) do
    min_refresh_ms = Application.get_env(:batcher, :ui_count_refresh_ms, 10_000)
    now_ms = System.monotonic_time(:millisecond)

    if skip_count_refresh?(socket, count_request_key, now_ms, min_refresh_ms) do
      socket
    else
      socket =
        socket
        |> assign(:count_request_key, count_request_key)
        |> assign(:page_total_count, nil)
        |> assign(:page_count_status, :loading)

      if Phoenix.LiveView.connected?(socket) do
        Phoenix.LiveView.start_async(socket, {:page_count, count_request_key}, count_fun)
      else
        socket
      end
    end
  end

  def handle_count_async(socket, count_request_key, {:ok, {:ok, count}})
      when is_integer(count) do
    if count_request_key == socket.assigns.count_request_key do
      socket
      |> assign(:page_total_count, count)
      |> assign(:page_count_status, :ready)
      |> assign(:count_last_success_at_ms, System.monotonic_time(:millisecond))
    else
      socket
    end
  end

  def handle_count_async(socket, count_request_key, {:ok, {:error, _error}}) do
    if count_request_key == socket.assigns.count_request_key do
      socket
      |> assign(:page_total_count, nil)
      |> assign(:page_count_status, :error)
    else
      socket
    end
  end

  def handle_count_async(socket, count_request_key, {:exit, _reason}) do
    if count_request_key == socket.assigns.count_request_key do
      socket
      |> assign(:page_total_count, nil)
      |> assign(:page_count_status, :error)
    else
      socket
    end
  end

  defp skip_count_refresh?(socket, count_request_key, now_ms, min_refresh_ms) do
    same_key? = socket.assigns.count_request_key == count_request_key
    loading? = socket.assigns.page_count_status == :loading
    ready? = socket.assigns.page_count_status == :ready
    last_success_at_ms = socket.assigns[:count_last_success_at_ms]

    recently_refreshed? =
      is_integer(last_success_at_ms) and now_ms - last_success_at_ms < min_refresh_ms

    same_key? and (loading? or (ready? and recently_refreshed?))
  end
end
