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

    case Batching.get_batch_by_id(batch_id, load: [:request_count, :size_bytes]) do
      {:ok, batch} ->
        {:ok, assign(socket, :batch, batch)}

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
  def handle_event("cancel_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.cancel_batch(batch) do
      {:ok, updated_batch} ->
        updated_batch = Ash.load!(updated_batch, [:request_count, :size_bytes])

        {:noreply,
         socket
         |> assign(:batch, updated_batch)
         |> put_flash(:info, "Batch cancelled successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel batch")}
    end
  end

  @impl true
  def handle_event("delete_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.destroy_batch(batch) do
      {:ok, _} ->
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
    batch = Ash.load!(batch, [:request_count, :size_bytes])
    {:noreply, assign(socket, :batch, batch)}
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
