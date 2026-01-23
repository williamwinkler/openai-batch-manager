defmodule BatcherWeb.RequestShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Batching.Types.DeliveryType

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
          |> assign(:editing_delivery_config, false)
          |> assign(:delivery_types, DeliveryType.options())
          |> assign_delivery_config_form_values(request.delivery_config)
          |> assign_delivery_config_form(request)

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
  def handle_event("retry_delivery", _params, socket) do
    request = socket.assigns.request

    case Batching.retry_request_delivery(request) do
      {:ok, updated_request} ->
        updated_request = Ash.load!(updated_request, :batch)
        {:noreply, assign(socket, :request, updated_request)}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Failed to retry delivery")}
    end
  end

  @impl true
  def handle_event("edit_delivery_config", _params, socket) do
    {:noreply, assign(socket, :editing_delivery_config, true)}
  end

  @impl true
  def handle_event("cancel_edit_delivery_config", _params, socket) do
    request = socket.assigns.request

    socket =
      socket
      |> assign(:editing_delivery_config, false)
      |> assign_delivery_config_form_values(request.delivery_config)
      |> assign_delivery_config_form(request)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_delivery_config", %{"form" => params}, socket) do
    # Update form assigns based on current params
    selected_type = params["delivery_type"] || socket.assigns.selected_delivery_type
    rabbitmq_mode = params["rabbitmq_mode"] || socket.assigns.form_rabbitmq_mode || "queue"
    webhook_url = params["webhook_url"] || socket.assigns.form_webhook_url || ""
    rabbitmq_queue = params["rabbitmq_queue"] || socket.assigns.form_rabbitmq_queue || ""
    rabbitmq_exchange = params["rabbitmq_exchange"] || socket.assigns.form_rabbitmq_exchange || ""
    rabbitmq_routing_key = params["rabbitmq_routing_key"] || socket.assigns.form_rabbitmq_routing_key || ""

    # Build merged params for validation
    merged_params = %{
      "delivery_type" => selected_type,
      "webhook_url" => webhook_url,
      "rabbitmq_mode" => rabbitmq_mode,
      "rabbitmq_queue" => rabbitmq_queue,
      "rabbitmq_exchange" => rabbitmq_exchange,
      "rabbitmq_routing_key" => rabbitmq_routing_key
    }

    # Build delivery_config and validate
    delivery_config = build_delivery_config(merged_params)

    form =
      socket.assigns.delivery_config_form
      |> AshPhoenix.Form.validate(%{"delivery_config" => delivery_config})

    socket =
      socket
      |> assign(:delivery_config_form, form)
      |> assign(:selected_delivery_type, selected_type)
      |> assign(:form_webhook_url, webhook_url)
      |> assign(:form_rabbitmq_mode, rabbitmq_mode)
      |> assign(:form_rabbitmq_queue, rabbitmq_queue)
      |> assign(:form_rabbitmq_exchange, rabbitmq_exchange)
      |> assign(:form_rabbitmq_routing_key, rabbitmq_routing_key)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_delivery_config", %{"form" => params}, socket) do
    # Use the current assigns (which have been kept in sync during validation)
    merged_params = %{
      "delivery_type" => params["delivery_type"] || socket.assigns.selected_delivery_type,
      "webhook_url" => params["webhook_url"] || socket.assigns.form_webhook_url || "",
      "rabbitmq_mode" => params["rabbitmq_mode"] || socket.assigns.form_rabbitmq_mode || "queue",
      "rabbitmq_queue" => params["rabbitmq_queue"] || socket.assigns.form_rabbitmq_queue || "",
      "rabbitmq_exchange" => params["rabbitmq_exchange"] || socket.assigns.form_rabbitmq_exchange || "",
      "rabbitmq_routing_key" => params["rabbitmq_routing_key"] || socket.assigns.form_rabbitmq_routing_key || ""
    }

    # Build the delivery_config from merged params
    delivery_config = build_delivery_config(merged_params)

    case AshPhoenix.Form.submit(socket.assigns.delivery_config_form,
           params: %{"delivery_config" => delivery_config}
         ) do
      {:ok, updated_request} ->
        updated_request = Ash.load!(updated_request, :batch)

        socket =
          socket
          |> assign(:request, updated_request)
          |> assign(:editing_delivery_config, false)
          |> assign_delivery_config_form_values(updated_request.delivery_config)
          |> assign_delivery_config_form(updated_request)
          |> put_flash(:info, "Delivery configuration updated")

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, :delivery_config_form, form)}
    end
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
    type = config["type"] || config[:type]

    case type do
      "webhook" -> "Webhook"
      "rabbitmq" -> "RabbitMQ"
      _ ->
        # Fallback for legacy configs without type field
        cond do
          Map.has_key?(config, "webhook_url") or Map.has_key?(config, :webhook_url) -> "Webhook"
          Map.has_key?(config, "rabbitmq_queue") or Map.has_key?(config, :rabbitmq_queue) -> "RabbitMQ"
          Map.has_key?(config, "rabbitmq_exchange") or Map.has_key?(config, :rabbitmq_exchange) -> "RabbitMQ"
          true -> "Unknown"
        end
    end
  end

  defp delivery_type(_), do: "—"

  defp delivery_destination(nil), do: "—"

  defp delivery_destination(config) when is_map(config) do
    cond do
      url = config["webhook_url"] || config[:webhook_url] ->
        url

      queue = config["rabbitmq_queue"] || config[:rabbitmq_queue] ->
        queue

      exchange = config["rabbitmq_exchange"] || config[:rabbitmq_exchange] ->
        routing_key = config["rabbitmq_routing_key"] || config[:rabbitmq_routing_key] || ""
        "#{exchange} → #{routing_key}"

      true ->
        "—"
    end
  end

  defp delivery_destination(_), do: "—"

  defp assign_delivery_config_form(socket, request) do
    form =
      AshPhoenix.Form.for_update(request, :update_delivery_config,
        domain: Batching,
        as: "form"
      )

    assign(socket, :delivery_config_form, form)
  end

  defp assign_delivery_config_form_values(socket, config) do
    socket
    |> assign(:selected_delivery_type, current_delivery_type(config))
    |> assign(:form_webhook_url, current_webhook_url(config))
    |> assign(:form_rabbitmq_mode, current_rabbitmq_mode(config))
    |> assign(:form_rabbitmq_queue, current_rabbitmq_queue(config))
    |> assign(:form_rabbitmq_exchange, current_rabbitmq_exchange(config))
    |> assign(:form_rabbitmq_routing_key, current_rabbitmq_routing_key(config))
  end

  defp current_rabbitmq_mode(nil), do: "queue"

  defp current_rabbitmq_mode(config) when is_map(config) do
    exchange = config["rabbitmq_exchange"] || config[:rabbitmq_exchange]

    if non_empty?(exchange), do: "exchange", else: "queue"
  end

  defp current_rabbitmq_mode(_), do: "queue"

  defp build_delivery_config(params) when is_map(params) do
    type = params["delivery_type"]

    case type do
      "webhook" ->
        %{"type" => "webhook", "webhook_url" => params["webhook_url"] || ""}

      "rabbitmq" ->
        # Default to "queue" mode if not specified (e.g., when first switching to rabbitmq)
        mode = params["rabbitmq_mode"] || "queue"

        case mode do
          "queue" ->
            %{"type" => "rabbitmq", "rabbitmq_queue" => params["rabbitmq_queue"] || ""}

          "exchange" ->
            %{
              "type" => "rabbitmq",
              "rabbitmq_exchange" => params["rabbitmq_exchange"] || "",
              "rabbitmq_routing_key" => params["rabbitmq_routing_key"] || ""
            }

          _ ->
            %{"type" => "rabbitmq", "rabbitmq_queue" => ""}
        end

      "" ->
        # No type selected yet
        %{}

      nil ->
        # No type selected yet
        %{}

      _ ->
        %{}
    end
  end

  defp build_delivery_config(_), do: %{}

  defp non_empty?(nil), do: false
  defp non_empty?(""), do: false
  defp non_empty?(_), do: true

  def current_delivery_type(nil), do: nil

  def current_delivery_type(config) when is_map(config) do
    type = config["type"] || config[:type]

    case type do
      "webhook" -> "webhook"
      "rabbitmq" -> "rabbitmq"
      _ ->
        # Fallback for legacy configs without type field
        cond do
          Map.has_key?(config, "webhook_url") or Map.has_key?(config, :webhook_url) -> "webhook"
          Map.has_key?(config, "rabbitmq_queue") or Map.has_key?(config, :rabbitmq_queue) -> "rabbitmq"
          Map.has_key?(config, "rabbitmq_exchange") or Map.has_key?(config, :rabbitmq_exchange) -> "rabbitmq"
          true -> nil
        end
    end
  end

  def current_delivery_type(_), do: nil

  def current_webhook_url(nil), do: ""

  def current_webhook_url(config) when is_map(config) do
    config["webhook_url"] || config[:webhook_url] || ""
  end

  def current_webhook_url(_), do: ""

  def current_rabbitmq_queue(nil), do: ""

  def current_rabbitmq_queue(config) when is_map(config) do
    config["rabbitmq_queue"] || config[:rabbitmq_queue] || ""
  end

  def current_rabbitmq_queue(_), do: ""

  def current_rabbitmq_exchange(nil), do: ""

  def current_rabbitmq_exchange(config) when is_map(config) do
    config["rabbitmq_exchange"] || config[:rabbitmq_exchange] || ""
  end

  def current_rabbitmq_exchange(_), do: ""

  def current_rabbitmq_routing_key(nil), do: ""

  def current_rabbitmq_routing_key(config) when is_map(config) do
    config["rabbitmq_routing_key"] || config[:rabbitmq_routing_key] || ""
  end

  def current_rabbitmq_routing_key(_), do: ""

  def get_form_errors(form) do
    try do
      case AshPhoenix.Form.errors(form) do
        errors when is_list(errors) ->
          Enum.map(errors, fn
            {field, {msg, _opts}} -> {field, msg}
            {field, msg} when is_binary(msg) -> {field, msg}
            other -> {:unknown, inspect(other)}
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end
end
