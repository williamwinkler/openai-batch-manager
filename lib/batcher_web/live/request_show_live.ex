defmodule BatcherWeb.RequestShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching

  @per_page 25

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    request_id = String.to_integer(id)

    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("requests:state_changed:#{request_id}")
      BatcherWeb.Endpoint.subscribe("request_delivery_attempts:created:#{request_id}")
    end

    case Ash.read_one(Batching.Request, id: request_id) do
      {:ok, request} ->
        request = Ash.load!(request, :batch)

        socket =
          socket
          |> assign(:current_path, ~p"/requests/#{request_id}")
          |> assign(:current_scope, nil)

        {:ok, load_request_data(socket, request, 1)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Request not found")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    request = socket.assigns.request
    socket = assign(socket, :current_path, ~p"/requests/#{request.id}")
    {:noreply, load_delivery_attempts(socket, request.id, page)}
  end

  @impl true
  def handle_event("paginate_attempts", %{"page" => page}, socket) do
    page = String.to_integer(page)
    request_id = socket.assigns.request.id
    {:noreply, push_patch(socket, to: ~p"/requests/#{request_id}?page=#{page}")}
  end

  @impl true
  def handle_info(
        %{topic: "requests:state_changed:" <> _request_id, payload: %{data: request}},
        socket
      ) do
    # Reload with batch relationship
    request = Ash.load!(request, :batch)
    {:noreply, assign(socket, :request, request)}
  end

  @impl true
  def handle_info(
        %{topic: "request_delivery_attempts:created:" <> _request_id, payload: %{data: attempt}},
        socket
      ) do
    # Only add if it belongs to this request
    if attempt.request_id == socket.assigns.request.id do
      {:noreply, stream(socket, :delivery_attempts, [attempt], reset: false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp load_request_data(socket, request, page) do
    socket
    |> assign(:request, request)
    |> load_delivery_attempts(request.id, page)
  end

  defp load_delivery_attempts(socket, request_id, page) do
    skip = (page - 1) * @per_page

    query =
      Batching.RequestDeliveryAttempt
      |> Ash.Query.for_read(:list_paginated, request_id: request_id, skip: skip, limit: @per_page)

    case Ash.read!(query, page: [offset: skip, limit: @per_page, count: true]) do
      %Ash.Page.Offset{results: attempts, count: total_count, more?: _more} ->
        socket
        |> stream(:delivery_attempts, attempts, reset: true)
        |> assign(:page, page)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, total_count || 0)

      _ ->
        socket
        |> stream(:delivery_attempts, [], reset: true)
        |> assign(:page, page)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, 0)
    end
  end
end
