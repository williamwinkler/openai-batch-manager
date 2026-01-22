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

    case Batching.get_request_by_id(request_id) do
      {:ok, request} ->
        request = Ash.load!(request, :batch)

        socket =
          socket
          |> load_request_data(request, 1)
          |> assign(:show_payload_modal, false)
          |> assign(:payload_modal_title, "")
          |> assign(:payload_modal_content, "")
          |> assign(:payload_modal_is_json, false)

        {:ok, socket}

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
    {:noreply, load_delivery_attempts(socket, request.id, page)}
  end

  @impl true
  def handle_event("paginate_attempts", %{"page" => page}, socket) do
    page = String.to_integer(page)
    request_id = socket.assigns.request.id
    {:noreply, push_patch(socket, to: ~p"/requests/#{request_id}?page=#{page}")}
  end

  @impl true
  def handle_event("show_request_payload", _params, socket) do
    content = format_json(socket.assigns.request.request_payload)

    socket =
      socket
      |> assign(:show_payload_modal, true)
      |> assign(:payload_modal_title, "Request Payload")
      |> assign(:payload_modal_content, content)
      |> assign(:payload_modal_is_json, true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_response_payload", _params, socket) do
    content = format_json(socket.assigns.request.response_payload)

    socket =
      socket
      |> assign(:show_payload_modal, true)
      |> assign(:payload_modal_title, "Response Payload")
      |> assign(:payload_modal_content, content)
      |> assign(:payload_modal_is_json, true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_error_msg", _params, socket) do
    error_msg = socket.assigns.request.error_msg
    {content, is_json} = format_content_with_type(error_msg)

    socket =
      socket
      |> assign(:show_payload_modal, true)
      |> assign(:payload_modal_title, "Error Message")
      |> assign(:payload_modal_content, content)
      |> assign(:payload_modal_is_json, is_json)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_payload_modal", _params, socket) do
    {:noreply, assign(socket, :show_payload_modal, false)}
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

  @doc """
  Format a JSON string or map for display with pretty printing.
  """
  def format_json(nil), do: ""

  def format_json(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      {:error, _} -> payload
    end
  end

  def format_json(payload) when is_map(payload) do
    Jason.encode!(payload, pretty: true)
  end

  def format_json(payload), do: inspect(payload)

  # Format content and return both the formatted content and whether it's JSON.
  # Returns {content, is_json}
  defp format_content_with_type(nil), do: {"", false}

  defp format_content_with_type(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {Jason.encode!(decoded, pretty: true), true}
      {:error, _} -> {content, false}
    end
  end

  defp format_content_with_type(content) when is_map(content) do
    {Jason.encode!(content, pretty: true), true}
  end

  defp format_content_with_type(content), do: {inspect(content), false}

  defp delivery_type(nil), do: "—"

  defp delivery_type(config) when is_map(config) do
    cond do
      Map.has_key?(config, "webhook_url") or Map.has_key?(config, :webhook_url) -> "Webhook"
      Map.has_key?(config, "rabbitmq_queue") or Map.has_key?(config, :rabbitmq_queue) -> "RabbitMQ"
      true -> "Unknown"
    end
  end

  defp delivery_type(_), do: "—"

  defp delivery_destination(nil), do: "—"

  defp delivery_destination(config) when is_map(config) do
    config["webhook_url"] || config[:webhook_url] ||
      config["rabbitmq_queue"] || config[:rabbitmq_queue] ||
      "—"
  end

  defp delivery_destination(_), do: "—"
end
