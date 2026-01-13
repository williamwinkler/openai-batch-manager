defmodule BatcherWeb.BatchShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching

  @per_page 25

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    batch_id = String.to_integer(id)

    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch_id}")
      # Subscribe to request creation events for this batch
      BatcherWeb.Endpoint.subscribe("requests:created")
    end

    case Batching.get_batch_by_id(batch_id) do
      {:ok, batch} ->
        socket =
          socket
          |> assign(:current_path, ~p"/batches/#{batch_id}")
          |> assign(:current_scope, nil)

        {:ok, load_batch_data(socket, batch, 1)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Batch not found")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    batch = socket.assigns.batch
    socket = assign(socket, :current_path, ~p"/batches/#{batch.id}")
    {:noreply, load_requests(socket, batch.id, page)}
  end

  @impl true
  def handle_event("paginate_requests", %{"page" => page}, socket) do
    page = String.to_integer(page)
    batch_id = socket.assigns.batch.id
    {:noreply, push_patch(socket, to: ~p"/batches/#{batch_id}?page=#{page}")}
  end

  @impl true
  def handle_event("cancel_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.cancel_batch(batch) do
      {:ok, updated_batch} ->
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
  def handle_info(%{topic: "batches:state_changed:" <> _batch_id, payload: %{data: batch}}, socket) do
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
  def handle_info(
        %{topic: "requests:created", payload: %{data: request}},
        socket
      ) do
    # Only add if request belongs to this batch
    if request.batch_id == socket.assigns.batch.id do
      # Reload requests to include the new one (respects pagination)
      page = socket.assigns[:page] || 1
      {:noreply, load_requests(socket, socket.assigns.batch.id, page)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "requests:created:" <> _request_id, payload: %{data: request}},
        socket
      ) do
    # Also handle individual request creation events
    if request.batch_id == socket.assigns.batch.id do
      page = socket.assigns[:page] || 1
      {:noreply, load_requests(socket, socket.assigns.batch.id, page)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "requests:state_changed:" <> _request_id, payload: %{data: request}},
        socket
      ) do
    # Only update if request belongs to this batch
    if request.batch_id == socket.assigns.batch.id do
      {:noreply, stream(socket, :requests, [request], reset: false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp load_batch_data(socket, batch, page) do
    socket
    |> assign(:batch, batch)
    |> load_requests(batch.id, page)
  end

  defp load_requests(socket, batch_id, page) do
    skip = (page - 1) * @per_page

    query =
      Batching.Request
      |> Ash.Query.for_read(:list_paginated, batch_id: batch_id, skip: skip, limit: @per_page)

    case Ash.read!(query, page: [offset: skip, limit: @per_page, count: true]) do
      %Ash.Page.Offset{results: requests, count: total_count, more?: _more} ->
        # Subscribe to PubSub for requests on current page
        if connected?(socket) do
          Enum.each(requests, fn request ->
            BatcherWeb.Endpoint.subscribe("requests:state_changed:#{request.id}")
          end)
        end

        socket
        |> stream(:requests, requests, reset: true)
        |> assign(:page, page)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, total_count || 0)

      _ ->
        socket
        |> stream(:requests, [], reset: true)
        |> assign(:page, page)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, 0)
    end
  end
end
