defmodule BatcherWeb.BatchShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Batching.CapacityControl
  alias Batcher.Utils.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    batch_id = String.to_integer(id)

    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:progress_updated:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:metrics_delta")
    end

    case Batching.get_batch_by_id(batch_id, load: [:transitions, :delivery_stats]) do
      {:ok, batch} ->
        transitions = batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:ok,
         socket
         |> assign(batch: batch, transitions: transitions, show_capacity_modal: false)
         |> assign(:show_error_modal, false)
         |> assign(:error_modal_content, "")
         |> assign(:error_modal_is_json, false)
         |> assign(:capacity_info, build_capacity_info(batch))
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
        updated_batch =
          Batching.get_batch_by_id!(updated_batch.id, load: [:transitions, :delivery_stats])

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
        updated_batch =
          Batching.get_batch_by_id!(updated_batch.id, load: [:transitions, :delivery_stats])

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
  def handle_event("restart_batch", _params, socket) do
    batch = socket.assigns.batch

    case Batching.restart_batch(batch) do
      {:ok, updated_batch} ->
        updated_batch =
          Batching.get_batch_by_id!(updated_batch.id, load: [:transitions, :delivery_stats])

        transitions = updated_batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

        {:noreply,
         socket
         |> assign(batch: updated_batch, transitions: transitions, show_error_modal: false)
         |> assign(:error_modal_content, "")
         |> assign(:error_modal_is_json, false)
         |> assign(:capacity_info, build_capacity_info(updated_batch))
         |> assign(delivery_bar_width_styles(updated_batch))
         |> put_flash(:info, "Batch restart initiated successfully")}

      {:error, error} ->
        error_msg =
          case error do
            %Ash.Error.Invalid{errors: errors} ->
              Enum.map_join(errors, ", ", &Exception.message/1)

            other ->
              "Failed to restart batch: #{Exception.message(other)}"
          end

        {:noreply, put_flash(socket, :error, error_msg)}
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
  def handle_event("show_batch_error", _params, socket) do
    {content, is_json} = format_content_with_type(socket.assigns.batch.error_msg)

    {:noreply,
     socket
     |> assign(:show_error_modal, true)
     |> assign(:error_modal_content, content)
     |> assign(:error_modal_is_json, is_json)}
  end

  @impl true
  def handle_event("close_batch_error_modal", _params, socket) do
    {:noreply, assign(socket, :show_error_modal, false)}
  end

  @impl true
  def handle_event("open_capacity_modal", _params, socket) do
    {:noreply, assign(socket, :show_capacity_modal, true)}
  end

  @impl true
  def handle_event("close_capacity_modal", _params, socket) do
    {:noreply, assign(socket, :show_capacity_modal, false)}
  end

  @impl true
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: batch}},
        socket
      ) do
    batch = Batching.get_batch_by_id!(batch.id, load: [:transitions, :delivery_stats])
    transitions = batch.transitions |> Enum.sort_by(& &1.transitioned_at, DateTime)

    {:noreply,
     socket
     |> assign(batch: batch, transitions: transitions, capacity_info: build_capacity_info(batch))
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
  def handle_info(
        %{topic: "batches:progress_updated:" <> _batch_id, payload: %{data: batch_data}},
        %{assigns: %{batch: batch}} = socket
      ) do
    updated_batch = %{
      batch
      | openai_requests_completed: batch_data.openai_requests_completed,
        openai_requests_failed: batch_data.openai_requests_failed,
        openai_requests_total: batch_data.openai_requests_total
    }

    {:noreply, assign(socket, :batch, updated_batch)}
  end

  @impl true
  def handle_info(
        %{
          topic: "batches:metrics_delta",
          payload:
            %{
              batch_id: batch_id,
              request_count_delta: request_count_delta,
              size_bytes_delta: size_bytes_delta,
              estimated_input_tokens_delta: estimated_input_tokens_delta
            } = payload
        },
        %{assigns: %{batch: batch}} = socket
      ) do
    if batch.id == batch_id do
      estimated_request_input_tokens_delta =
        Map.get(payload, :estimated_request_input_tokens_delta, 0)

      updated_batch = %{
        batch
        | request_count: (batch.request_count || 0) + request_count_delta,
          size_bytes: (batch.size_bytes || 0) + size_bytes_delta,
          estimated_input_tokens_total:
            (batch.estimated_input_tokens_total || 0) + estimated_input_tokens_delta,
          estimated_request_input_tokens_total:
            (batch.estimated_request_input_tokens_total || 0) +
              estimated_request_input_tokens_delta
      }

      {:noreply,
       socket
       |> assign(batch: updated_batch, capacity_info: build_capacity_info(updated_batch))
       |> assign(delivery_bar_width_styles(updated_batch))}
    else
      {:noreply, socket}
    end
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

  defp build_capacity_info(batch) do
    {:ok, %{limit: limit, source: limit_source}} =
      Batcher.OpenaiRateLimits.get_batch_limit_tokens(batch.model)

    {:ok, reserved_other} =
      CapacityControl.reserved_tokens_for_model(batch.model, exclude_batch_id: batch.id)

    estimated_tokens = batch.estimated_request_input_tokens_total || 0
    reserved_total = reserved_other + estimated_tokens
    headroom = max(limit - reserved_other, 0)
    would_exceed_by = max(reserved_total - limit, 0)

    %{
      model: batch.model,
      limit: limit,
      reserved_other: reserved_other,
      estimated_tokens: estimated_tokens,
      reserved_total: reserved_total,
      headroom: headroom,
      would_exceed_by: would_exceed_by,
      limit_source: limit_source,
      waiting_reason: format_wait_reason(batch.capacity_wait_reason),
      token_limit_retry_attempts: batch.token_limit_retry_attempts || 0,
      token_limit_retry_next_at: batch.token_limit_retry_next_at
    }
  end

  defp format_wait_reason("insufficient_headroom"), do: "Insufficient queue headroom"

  defp format_wait_reason("token_limit_exceeded"),
    do: "OpenAI rejected batch (token limit exceeded)"

  defp format_wait_reason("token_limit_exceeded_backoff"),
    do: "OpenAI queue backoff in progress (token limit exceeded)"

  defp format_wait_reason(nil), do: "Waiting for queue capacity"
  defp format_wait_reason(other), do: other

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

  defp token_limit_backoff_waiting?(batch) do
    batch.state == :waiting_for_capacity and
      batch.capacity_wait_reason == "token_limit_exceeded_backoff"
  end

  defp token_limit_retry_time_remaining(nil), do: "—"

  defp token_limit_retry_time_remaining(next_at) do
    seconds = DateTime.diff(next_at, DateTime.utc_now(), :second)

    cond do
      seconds <= 0 -> "Retrying now"
      seconds < 60 -> "<1m"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
    end
  end
end
