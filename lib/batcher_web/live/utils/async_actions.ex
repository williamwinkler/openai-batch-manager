defmodule BatcherWeb.Live.Utils.AsyncActions do
  @moduledoc """
  Shared helpers for LiveView async action handling with per-action pending state.
  """

  import Phoenix.LiveView

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

  @spec clear_pending(Phoenix.LiveView.Socket.t(), action_key()) :: Phoenix.LiveView.Socket.t()
  def clear_pending(socket, key) do
    Phoenix.Component.update(socket, :pending_actions, &MapSet.delete(&1, key))
  end
end
