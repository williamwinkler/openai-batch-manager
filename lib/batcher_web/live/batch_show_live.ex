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

    case Batching.get_batch_by_id(batch_id, load: [:transitions, :delivery_stats]) do
      {:ok, batch} ->
        transitions = batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:ok,
         socket
         |> assign(batch: batch, transitions: transitions)
         |> assign(delivery_bar_width_styles(batch))}

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
        updated_batch = Ash.load!(updated_batch, [:transitions, :delivery_stats])

        transitions = updated_batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:noreply,
         socket
         |> assign(batch: updated_batch, transitions: transitions)
         |> assign(delivery_bar_width_styles(updated_batch))
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
        updated_batch = Ash.load!(updated_batch, [:transitions, :delivery_stats])

        transitions = updated_batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:noreply,
         socket
         |> assign(batch: updated_batch, transitions: transitions)
         |> assign(delivery_bar_width_styles(updated_batch))
         |> put_flash(:info, "Batch cancelled successfully")}

      {:error, error} ->
        error_msg =
          case error do
            %Ash.Error.Invalid{errors: errors} ->
              Enum.map_join(errors, ", ", fn e ->
                # Handle NoMatchingTransition errors specifically
                case e do
                  %AshStateMachine.Errors.NoMatchingTransition{
                    old_state: old_state,
                    target: target
                  } ->
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
         |> redirect(to: ~p"/batches")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete batch")}
    end
  end

  @impl true
  def handle_event("redeliver_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.redeliver_batch(batch.id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Redelivery initiated for failed requests")}

      {:error, error} ->
        error_msg =
          case error do
            %Ash.Error.Invalid{errors: errors} ->
              Enum.map_join(errors, ", ", &Exception.message/1)

            other ->
              "Failed to redeliver: #{Exception.message(other)}"
          end

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: batch}},
        socket
      ) do
    batch = Ash.load!(batch, [:transitions, :delivery_stats])
    transitions = batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

    {:noreply,
     socket
     |> assign(batch: batch, transitions: transitions)
     |> assign(delivery_bar_width_styles(batch))}
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

  defp delivery_bar_width_styles(batch) do
    total = batch.request_count || 0
    delivered = batch.delivery_stats[:delivered] || 0
    delivering = batch.delivery_stats[:delivering] || 0
    failed = batch.delivery_stats[:failed] || 0

    {delivered_pct, delivering_pct, failed_pct} =
      if total > 0 do
        {delivered / total * 100, delivering / total * 100, failed / total * 100}
      else
        {0, 0, 0}
      end

    [
      delivered_width_style: "width: #{delivered_pct}%",
      delivering_width_style: "width: #{delivering_pct}%",
      failed_width_style: "width: #{failed_pct}%"
    ]
  end
end
