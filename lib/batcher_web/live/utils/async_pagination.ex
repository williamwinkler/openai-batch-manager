defmodule BatcherWeb.Live.Utils.AsyncPagination do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  require Phoenix.LiveView

  def init(socket) do
    socket
    |> assign(:page_count_status, :loading)
    |> assign(:page_total_count, nil)
    |> assign(:count_request_key, nil)
  end

  def schedule_count(socket, count_request_key, count_fun) do
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

  def handle_count_async(socket, count_request_key, {:ok, {:ok, count}})
      when is_integer(count) do
    if count_request_key == socket.assigns.count_request_key do
      socket
      |> assign(:page_total_count, count)
      |> assign(:page_count_status, :ready)
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
end
