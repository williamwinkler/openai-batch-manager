defmodule BatcherWeb.BatchShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Utils.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    batch_id = String.to_integer(id)

    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch_id}")
    end

    case Batching.get_batch_by_id(batch_id, load: [:request_count, :size_bytes, :transitions, :delivery_stats]) do
      {:ok, batch} ->
        transitions = batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)
        {:ok, assign(socket, batch: batch, transitions: transitions)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Batch not found")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.start_batch_upload(batch) do
      {:ok, updated_batch} ->
        updated_batch = Ash.load!(updated_batch, [:request_count, :size_bytes, :transitions, :delivery_stats])
        transitions = updated_batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:noreply,
         socket
         |> assign(batch: updated_batch, transitions: transitions)
         |> put_flash(:info, "Batch upload started")}

      {:error, error} ->
        error_msg =
          case error do
            %Ash.Error.Invalid{errors: errors} ->
              Enum.map_join(errors, ", ", &Exception.message/1)

            other ->
              "Failed to start upload: #{Exception.message(other)}"
          end

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("cancel_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.cancel_batch(batch) do
      {:ok, updated_batch} ->
        updated_batch = Ash.load!(updated_batch, [:request_count, :size_bytes, :transitions, :delivery_stats])
        transitions = updated_batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:noreply,
         socket
         |> assign(batch: updated_batch, transitions: transitions)
         |> put_flash(:info, "Batch cancelled successfully")}

      {:error, error} ->
        error_msg =
          case error do
            %Ash.Error.Invalid{errors: errors} ->
              Enum.map_join(errors, ", ", fn e ->
                # Handle NoMatchingTransition errors specifically
                case e do
                  %AshStateMachine.Errors.NoMatchingTransition{old_state: old_state, target: target} ->
                    "Cannot transition batch from #{old_state} to #{target} state"

                  _ ->
                    # Use Exception.message for other error types
                    Exception.message(e)
                end
              end)

            other ->
              "Failed to cancel batch: #{Exception.message(other)}"
          end

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("delete_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.destroy_batch(batch) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Batch deleted successfully")
         |> redirect(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete batch")}
    end
  end

  @impl true
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: batch}},
        socket
      ) do
    batch = Ash.load!(batch, [:request_count, :size_bytes, :transitions, :delivery_stats])
    transitions = batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)
    {:noreply, assign(socket, batch: batch, transitions: transitions)}
  end

  @impl true
  def handle_info(%{topic: "batches:destroyed:" <> _batch_id, _payload: _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Batch was deleted")
     |> redirect(to: ~p"/")}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end
end
