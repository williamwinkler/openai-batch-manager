defmodule BatcherWeb.Live.Utils.AsyncSections do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  @type section_key :: atom()
  @type section_status :: :idle | :loading_initial | :refreshing | :ready | :error

  @spec init_section(Phoenix.LiveView.Socket.t(), section_key(), term(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def init_section(socket, key, initial_data, opts \\ []) do
    data_assign = opts[:data_assign] || :"#{key}_data"

    socket
    |> assign(data_assign, initial_data)
    |> assign(:"#{key}_status", :idle)
    |> assign(:"#{key}_request_key", nil)
  end

  @spec status(Phoenix.LiveView.Socket.t(), section_key()) :: section_status()
  def status(socket, key), do: socket.assigns[:"#{key}_status"] || :idle

  @spec loading?(Phoenix.LiveView.Socket.t(), section_key()) :: boolean()
  def loading?(socket, key), do: status(socket, key) in [:loading_initial, :refreshing]

  @spec load_section(
          Phoenix.LiveView.Socket.t(),
          section_key(),
          term(),
          (-> term()),
          keyword()
        ) :: Phoenix.LiveView.Socket.t()
  def load_section(socket, key, request_key, fun, opts \\ []) when is_function(fun, 0) do
    async_name = opts[:async_name] || {:section, key, request_key}
    first_load? = opts[:first_load?] || first_load?(socket, key)
    loading_status = if first_load?, do: :loading_initial, else: :refreshing

    socket =
      socket
      |> assign(:"#{key}_request_key", request_key)
      |> assign(:"#{key}_status", loading_status)

    if connected?(socket) do
      start_async(socket, async_name, fun)
    else
      socket
    end
  end

  @spec handle_section_async(
          Phoenix.LiveView.Socket.t(),
          section_key(),
          term(),
          {:ok, term()} | {:exit, term()},
          keyword()
        ) :: Phoenix.LiveView.Socket.t()
  def handle_section_async(socket, key, request_key, result, opts \\ []) do
    data_assign = opts[:data_assign] || :"#{key}_data"

    if socket.assigns[:"#{key}_request_key"] != request_key do
      socket
    else
      case result do
        {:ok, {:ok, data}} ->
          socket
          |> assign(data_assign, data)
          |> assign(:"#{key}_status", :ready)

        {:ok, {:error, _reason}} ->
          assign(socket, :"#{key}_status", :error)

        {:ok, data} ->
          socket
          |> assign(data_assign, data)
          |> assign(:"#{key}_status", :ready)

        {:exit, _reason} ->
          assign(socket, :"#{key}_status", :error)
      end
    end
  end

  defp first_load?(socket, key) do
    status(socket, key) in [:idle, :loading_initial]
  end
end
