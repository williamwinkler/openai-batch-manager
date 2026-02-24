defmodule BatcherWeb.RequestShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Batching.Types.DeliveryType
  alias BatcherWeb.Live.Utils.ActionActivity
  alias BatcherWeb.Live.Utils.AsyncActions
  alias BatcherWeb.Live.Utils.AsyncSections

  @per_page 5

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    request_id = String.to_integer(id)

    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("requests:state_changed:#{request_id}")
      BatcherWeb.Endpoint.subscribe("request_delivery_attempts:created:#{request_id}")
      ActionActivity.subscribe({:request, request_id})
    end

    case Batching.get_request_by_id(request_id, load: [:batch]) do
      {:ok, request} ->
        socket =
          socket
          |> assign(:request, request)
          |> assign(:batch, request.batch)
          |> stream(:delivery_attempts, [], reset: true)
          |> assign(:delivery_attempts_page, nil)
          |> assign(:pending_actions, MapSet.new())
          |> assign(:action_activity_version, 0)
          |> assign(:show_payload_modal, false)
          |> assign(:payload_modal_title, "")
          |> assign(:payload_modal_content, "")
          |> assign(:payload_modal_is_json, false)
          |> assign(:payload_modal_status, :idle)
          |> assign(:payload_modal_request_key, nil)
          |> assign(:request_refresh_request_key, nil)
          |> assign(:editing_delivery_config, false)
          |> assign(
            :delivery_types,
            Enum.map(DeliveryType.values(), &{DeliveryType.label(&1), to_string(&1)})
          )
          |> assign_delivery_config_form_values(request.delivery_config)
          |> assign_delivery_config_form(request)
          |> AsyncSections.init_section(:delivery_attempts, nil,
            data_assign: :delivery_attempts_page
          )

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
    offset = parse_offset(params["offset"])
    request = socket.assigns.request
    key = {:delivery_attempts, request.id, offset, @per_page}

    {:noreply,
     AsyncSections.load_section(
       socket,
       :delivery_attempts,
       key,
       fn ->
         load_delivery_attempts_page(request.id, offset)
       end,
       async_name: {:request_show_section, key},
       data_assign: :delivery_attempts_page
     )}
  end

  @impl true
  def handle_event("show_request_payload", _params, socket) do
    open_payload_modal_async(
      socket,
      "Request Payload",
      {:json, socket.assigns.request.request_payload}
    )
  end

  @impl true
  def handle_event("show_response_payload", _params, socket) do
    open_payload_modal_async(
      socket,
      "Response Payload",
      {:json, socket.assigns.request.response_payload}
    )
  end

  @impl true
  def handle_event("show_error_msg", _params, socket) do
    open_payload_modal_async(
      socket,
      "Error Message",
      {:content, socket.assigns.request.error_msg}
    )
  end

  @impl true
  def handle_event("show_attempt_delivery_config", %{"config" => config_json}, socket) do
    config =
      case Jason.decode(config_json) do
        {:ok, decoded} -> decoded
        _ -> config_json
      end

    open_payload_modal_async(socket, "Delivery Configuration", {:json, config})
  end

  @impl true
  def handle_event("show_attempt_error", %{"error" => error_msg}, socket) do
    open_payload_modal_async(socket, "Delivery Error", {:content, error_msg})
  end

  @impl true
  def handle_event("close_payload_modal", _params, socket) do
    {:noreply,
     socket |> assign(:show_payload_modal, false) |> assign(:payload_modal_status, :idle)}
  end

  @impl true
  def handle_event("retry_delivery", _params, socket) do
    request_id = socket.assigns.request.id
    key = {:request_action, :retry_delivery, request_id}

    AsyncActions.start_shared_action(
      socket,
      key,
      fn ->
        maybe_test_async_delay()
        request = Batching.get_request_by_id!(request_id)

        case Batching.retry_request_delivery(request) do
          {:ok, updated_request} ->
            refreshed_request = Batching.get_request_by_id!(updated_request.id, load: [:batch])

            {:ok,
             %{type: :retry_delivery, request: refreshed_request, batch: refreshed_request.batch}}

          {:error, error} ->
            {:error, "Failed to retry delivery: #{Exception.message(error)}"}
        end
      end,
      scope: {:request, request_id}
    )
  end

  @impl true
  def handle_event("delete_request", _params, socket) do
    request_id = socket.assigns.request.id
    key = {:request_action, :delete_request, request_id}
    batch_state = socket.assigns.batch.state

    AsyncActions.start_shared_action(
      socket,
      key,
      fn ->
        maybe_test_async_delay()
        request = Batching.get_request_by_id!(request_id)

        if batch_state == :building do
          case Batching.destroy_request(request) do
            :ok -> {:ok, %{type: :delete_request}}
            {:error, _error} -> {:error, "Failed to delete request"}
          end
        else
          {:error, "Can only delete requests in building batches"}
        end
      end,
      scope: {:request, request_id}
    )
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
    webhook_url = params["webhook_url"] || socket.assigns.form_webhook_url || ""
    rabbitmq_queue = params["rabbitmq_queue"] || socket.assigns.form_rabbitmq_queue || ""

    # Build merged params for validation
    merged_params = %{
      "delivery_type" => selected_type,
      "webhook_url" => webhook_url,
      "rabbitmq_queue" => rabbitmq_queue
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
      |> assign(:form_rabbitmq_queue, rabbitmq_queue)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_delivery_config", %{"form" => params}, socket) do
    # Use the current assigns (which have been kept in sync during validation)
    merged_params = %{
      "delivery_type" => params["delivery_type"] || socket.assigns.selected_delivery_type,
      "webhook_url" => params["webhook_url"] || socket.assigns.form_webhook_url || "",
      "rabbitmq_queue" => params["rabbitmq_queue"] || socket.assigns.form_rabbitmq_queue || ""
    }

    # Build the delivery_config from merged params
    delivery_config = build_delivery_config(merged_params)

    request_id = socket.assigns.request.id
    key = {:request_action, :save_delivery_config, request_id}
    delivery_config_form = socket.assigns.delivery_config_form

    AsyncActions.start_shared_action(
      socket,
      key,
      fn ->
        maybe_test_async_delay()

        case AshPhoenix.Form.submit(delivery_config_form,
               params: %{"delivery_config" => delivery_config}
             ) do
          {:ok, updated_request} ->
            updated_request = Batching.get_request_by_id!(updated_request.id, load: [:batch])

            {:ok,
             %{
               type: :save_delivery_config,
               request: updated_request,
               batch: updated_request.batch
             }}

          {:error, form} ->
            {:error, %{message: "Please fix the form errors", form: form}}
        end
      end,
      scope: {:request, request_id}
    )
  end

  @impl true
  def handle_async({:request_action, action, request_id}, {:ok, result}, socket) do
    key = {:request_action, action, request_id}
    socket = AsyncActions.clear_shared_pending(socket, key, scope: {:request, request_id})

    case result do
      {:ok, %{type: :retry_delivery, request: request, batch: batch}} ->
        {:noreply,
         socket
         |> assign(:request, request)
         |> assign(:batch, batch)
         |> put_flash(:info, "Redelivery triggered")}

      {:ok, %{type: :delete_request}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Request deleted")
         |> redirect(to: ~p"/requests")}

      {:ok, %{type: :save_delivery_config, request: updated_request, batch: batch}} ->
        {:noreply,
         socket
         |> assign(:request, updated_request)
         |> assign(:batch, batch)
         |> assign(:editing_delivery_config, false)
         |> assign_delivery_config_form_values(updated_request.delivery_config)
         |> assign_delivery_config_form(updated_request)
         |> put_flash(:info, "Delivery configuration updated")}

      {:error, %{message: msg, form: form}} ->
        {:noreply, socket |> put_flash(:error, msg) |> assign(:delivery_config_form, form)}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_async({:request_action, action, request_id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> AsyncActions.clear_shared_pending({:request_action, action, request_id},
       scope: {:request, request_id}
     )
     |> put_flash(:error, "Action failed unexpectedly: #{inspect(reason)}")}
  end

  @impl true
  def handle_async(
        {:request_show_section, {:delivery_attempts, request_id, offset, per_page}},
        result,
        socket
      ) do
    key = {:delivery_attempts, request_id, offset, per_page}

    socket =
      AsyncSections.handle_section_async(socket, :delivery_attempts, key, result,
        data_assign: :delivery_attempts_page
      )

    case socket.assigns.delivery_attempts_page do
      %{results: results} ->
        {:noreply, stream(socket, :delivery_attempts, results, reset: true)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:payload_modal, request_key}, result, socket) do
    if socket.assigns.payload_modal_request_key == request_key do
      case result do
        {:ok, {content, is_json}} ->
          {:noreply,
           socket
           |> assign(:payload_modal_content, content)
           |> assign(:payload_modal_is_json, is_json)
           |> assign(:payload_modal_status, :ready)}

        {:exit, _reason} ->
          {:noreply,
           socket
           |> assign(:payload_modal_content, "")
           |> assign(:payload_modal_is_json, false)
           |> assign(:payload_modal_status, :error)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:request_refresh, request_key}, {:ok, {:ok, request}}, socket) do
    if socket.assigns.request_refresh_request_key == request_key do
      {:noreply, socket |> assign(:request, request) |> assign(:batch, request.batch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:request_refresh, request_key}, _result, socket) do
    if socket.assigns.request_refresh_request_key == request_key do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "requests:state_changed:" <> _request_id, payload: %{data: request}},
        socket
      ) do
    request_key = {:request_refresh, request.id, System.unique_integer([:positive])}

    {:noreply,
     socket
     |> assign(:request_refresh_request_key, request_key)
     |> start_async({:request_refresh, request_key}, fn ->
       Batching.get_request_by_id(request.id, load: [:batch])
     end)}
  end

  @impl true
  def handle_info(
        %{topic: "request_delivery_attempts:created:" <> _request_id, payload: %{data: attempt}},
        socket
      ) do
    # Only reload if it belongs to this request
    if attempt.request_id == socket.assigns.request.id do
      request_id = socket.assigns.request.id
      key = {:delivery_attempts, request_id, 0, @per_page}

      {:noreply,
       AsyncSections.load_section(
         socket,
         :delivery_attempts,
         key,
         fn ->
           load_delivery_attempts_page(request_id, 0)
         end,
         async_name: {:request_show_section, key},
         data_assign: :delivery_attempts_page
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{topic: "ui_actions:request:" <> _request_id}, socket) do
    {:noreply, update(socket, :action_activity_version, &(&1 + 1))}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp load_delivery_attempts_page(request_id, offset) do
    Batching.list_delivery_attempts_paginated!(
      request_id,
      offset,
      @per_page,
      page: [offset: offset, limit: @per_page, count: true]
    )
  end

  @doc """
  Returns the request input estimate shown in the UI.

  Prefers actual token usage from response payload when available, otherwise uses the
  persisted estimate, and applies the default 10% safety buffer.
  """
  def estimated_input_from_actual(request) do
    actual_input_tokens = extract_actual_input_tokens(request.response_payload)

    base_tokens =
      cond do
        is_integer(actual_input_tokens) and actual_input_tokens >= 0 ->
          actual_input_tokens

        true ->
          request.estimated_request_input_tokens || 0
      end

    trunc(Float.ceil(base_tokens * 1.1))
  end

  defp extract_actual_input_tokens(nil), do: nil

  defp extract_actual_input_tokens(response_payload) when is_map(response_payload) do
    usage_paths = [
      ["response", "body", "usage", "input_tokens"],
      ["response", "body", "usage", "prompt_tokens"],
      ["response", "usage", "input_tokens"],
      ["response", "usage", "prompt_tokens"],
      ["usage", "input_tokens"],
      ["usage", "prompt_tokens"]
    ]

    Enum.find_value(usage_paths, fn path ->
      get_in_mixed(response_payload, path)
    end)
  end

  defp extract_actual_input_tokens(_), do: nil

  defp get_in_mixed(data, []), do: data

  defp get_in_mixed(data, [key | rest]) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        get_in_mixed(value, rest)

      :error ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom_key do
          case Map.fetch(data, atom_key) do
            {:ok, value} -> get_in_mixed(value, rest)
            :error -> nil
          end
        else
          nil
        end
    end
  end

  defp get_in_mixed(_data, _path), do: nil

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

  @doc """
  Format bytes into a human-readable string.
  """
  def format_bytes(nil), do: "—"
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"

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
      "webhook" ->
        "Webhook"

      "rabbitmq" ->
        "RabbitMQ"

      _ ->
        # Fallback for legacy configs without type field
        cond do
          Map.has_key?(config, "webhook_url") or Map.has_key?(config, :webhook_url) ->
            "Webhook"

          Map.has_key?(config, "rabbitmq_queue") or Map.has_key?(config, :rabbitmq_queue) ->
            "RabbitMQ"

          true ->
            "Unknown"
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
    |> assign(:form_rabbitmq_queue, current_rabbitmq_queue(config))
  end

  defp build_delivery_config(params) when is_map(params) do
    type = params["delivery_type"]

    case type do
      "webhook" ->
        %{"type" => "webhook", "webhook_url" => params["webhook_url"] || ""}

      "rabbitmq" ->
        %{"type" => "rabbitmq", "rabbitmq_queue" => params["rabbitmq_queue"] || ""}

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

  @doc """
  Returns the normalized delivery type (`\"webhook\"` or `\"rabbitmq\"`) from config.
  """
  def current_delivery_type(nil), do: nil

  def current_delivery_type(config) when is_map(config) do
    type = config["type"] || config[:type]

    case type do
      "webhook" ->
        "webhook"

      "rabbitmq" ->
        "rabbitmq"

      _ ->
        # Fallback for legacy configs without type field
        cond do
          Map.has_key?(config, "webhook_url") or Map.has_key?(config, :webhook_url) ->
            "webhook"

          Map.has_key?(config, "rabbitmq_queue") or Map.has_key?(config, :rabbitmq_queue) ->
            "rabbitmq"

          true ->
            nil
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

  def pending_action?(pending_actions, action, request_id) do
    key = {:request_action, action, request_id}
    AsyncActions.pending?(pending_actions, key) or ActionActivity.active?(key)
  end

  def loading_delivery_attempts?(status), do: status in [:loading_initial, :refreshing]

  def loading_payload_modal?(status), do: status == :loading

  defp open_payload_modal_async(socket, title, payload) do
    request_key = {title, System.unique_integer([:positive])}

    socket =
      socket
      |> assign(:show_payload_modal, true)
      |> assign(:payload_modal_title, title)
      |> assign(:payload_modal_content, "")
      |> assign(:payload_modal_is_json, false)
      |> assign(:payload_modal_status, :loading)
      |> assign(:payload_modal_request_key, request_key)
      |> start_async({:payload_modal, request_key}, fn ->
        case payload do
          {:json, content} -> {format_json(content), true}
          {:content, content} -> format_content_with_type(content)
        end
      end)

    {:noreply, socket}
  end

  defp parse_offset(nil), do: 0

  defp parse_offset(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp parse_offset(_), do: 0

  defp maybe_test_async_delay do
    case Application.get_env(:batcher, :batch_action_test_delay_ms, 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end
end
