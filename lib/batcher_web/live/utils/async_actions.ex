defmodule BatcherWeb.Live.Utils.AsyncActions do
  @moduledoc """
  Shared helpers for LiveView async action handling with per-action pending state.
  """

  import Phoenix.LiveView
  alias BatcherWeb.Live.Utils.ActionActivity

  @type action_key :: tuple()

  @spec pending?(MapSet.t(), action_key()) :: boolean()
  def pending?(pending_actions, key), do: MapSet.member?(pending_actions, key)

  @spec start_action(Phoenix.LiveView.Socket.t(), action_key(), (-> term())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def start_action(socket, key, fun) when is_function(fun, 0) do
    if pending?(socket.assigns.pending_actions, key) do
      {:noreply, socket}
    else
      socket =
        socket
        |> Phoenix.Component.update(:pending_actions, &MapSet.put(&1, key))
        |> start_async(key, fun)

      {:noreply, socket}
    end
  end

  @spec start_shared_action(
          Phoenix.LiveView.Socket.t(),
          action_key(),
          (-> term()),
          Keyword.t()
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def start_shared_action(socket, key, fun, opts \\ []) when is_function(fun, 0) do
    scope = Keyword.get(opts, :scope)
    ttl_ms = Keyword.get(opts, :ttl_ms)

    if pending?(socket.assigns.pending_actions, key) or ActionActivity.active?(key) do
      {:noreply, socket}
    else
      start_opts = [scope: scope] |> maybe_put(:ttl_ms, ttl_ms)

      case ActionActivity.start(key, start_opts) do
        :ok ->
          socket =
            socket
            |> Phoenix.Component.update(:pending_actions, &MapSet.put(&1, key))
            |> start_async(key, fun)

          {:noreply, socket}

        :already_running ->
          {:noreply, socket}
      end
    end
  end

  @spec clear_pending(Phoenix.LiveView.Socket.t(), action_key()) :: Phoenix.LiveView.Socket.t()
  def clear_pending(socket, key) do
    Phoenix.Component.update(socket, :pending_actions, &MapSet.delete(&1, key))
  end

  @spec clear_shared_pending(Phoenix.LiveView.Socket.t(), action_key(), Keyword.t()) ::
          Phoenix.LiveView.Socket.t()
  def clear_shared_pending(socket, key, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    ActionActivity.finish(key, scope: scope)
    clear_pending(socket, key)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
