defmodule BatcherWeb.BatchShowLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Batching.CapacityControl
  alias BatcherWeb.Live.Utils.ActionActivity
  alias BatcherWeb.Live.Utils.AsyncActions
  alias Batcher.Utils.Format

  @delivery_stats_refresh_throttle_ms 2_000
  @delivery_stats_fallback_poll_ms 20_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    batch_id = String.to_integer(id)

    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:progress_updated:#{batch_id}")
      BatcherWeb.Endpoint.subscribe("batches:metrics_delta")
      ActionActivity.subscribe({:batch, batch_id})
    end

    case Batching.get_batch_by_id(batch_id) do
      {:ok, batch} ->
        socket =
          socket
          |> assign(:delivery_stats_dirty, false)
          |> assign(:delivery_stats_refresh_scheduled, false)
          |> assign(:delivery_stats_refresh_inflight, false)
          |> assign(:last_delivery_stats_refresh_at_ms, 0)

        socket =
          if connected?(socket) do
            schedule_delivery_stats_fallback_tick()
            socket
          else
            socket
          end

        {:ok,
         socket
         |> assign(batch: batch, show_capacity_modal: false)
         |> assign(:transitions, [])
         |> assign(:delivery_stats, %{})
         |> assign(:timeline_status, :loading_initial)
         |> assign(:timeline_request_key, nil)
         |> assign(:delivery_stats_status, :loading_initial)
         |> assign(:delivery_stats_request_key, nil)
         |> assign(:pending_actions, MapSet.new())
         |> assign(:action_activity_version, 0)
         |> assign(:show_error_modal, false)
         |> assign(:error_modal_content, "")
         |> assign(:error_modal_is_json, false)
         |> assign(:error_modal_status, :idle)
         |> assign(:error_modal_request_key, nil)
         |> assign(:capacity_info, nil)
         |> assign(:capacity_info_status, :idle)
         |> assign(:capacity_info_stale, true)
         |> assign(:batch_refresh_request_key, nil)
         |> start_section_loads(batch.id)}

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
  def handle_event("upload_batch", _params, socket),
    do: start_current_batch_action_async(socket, :upload)

  @impl true
  def handle_event("cancel_batch", _params, socket),
    do: start_current_batch_action_async(socket, :cancel)

  @impl true
  def handle_event("delete_batch", _params, socket),
    do: start_current_batch_action_async(socket, :delete)

  @impl true
  def handle_event("restart_batch", _params, socket),
    do: start_current_batch_action_async(socket, :restart)

  @impl true
  def handle_event("redeliver_batch", _params, socket),
    do: start_current_batch_action_async(socket, :redeliver)

  @impl true
  def handle_event("show_batch_error", _params, socket) do
    request_key = {:batch_error, socket.assigns.batch.id, System.unique_integer([:positive])}
    error_msg = socket.assigns.batch.error_msg

    socket =
      socket
      |> assign(:show_error_modal, true)
      |> assign(:error_modal_content, "")
      |> assign(:error_modal_is_json, false)
      |> assign(:error_modal_status, :loading)
      |> assign(:error_modal_request_key, request_key)
      |> start_async({:batch_error_modal, request_key}, fn ->
        format_content_with_type(error_msg)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_batch_error_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_error_modal, false)
     |> assign(:error_modal_status, :idle)}
  end

  @impl true
  def handle_event("open_capacity_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_capacity_modal, true)
      |> maybe_load_capacity_info()

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_capacity_modal", _params, socket) do
    {:noreply, assign(socket, :show_capacity_modal, false)}
  end

  @impl true
  def handle_async({:batch_action, action, batch_id}, {:ok, result}, socket) do
    key = {:batch_action, action, batch_id}
    socket = AsyncActions.clear_shared_pending(socket, key, scope: {:batch, batch_id})

    case result do
      {:ok, :delete, message} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> redirect(to: ~p"/batches")}

      {:ok, :restart, message} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(:show_error_modal, false)
         |> assign(:error_modal_content, "")
         |> assign(:error_modal_is_json, false)
         |> assign(:error_modal_status, :idle)}

      {:ok, _action, message} ->
        {:noreply, put_flash(socket, :info, message)}

      {:error, error_message} ->
        {:noreply, put_flash(socket, :error, error_message)}
    end
  end

  @impl true
  def handle_async({:batch_action, action, batch_id}, {:exit, reason}, socket) do
    key = {:batch_action, action, batch_id}

    socket =
      socket
      |> AsyncActions.clear_shared_pending(key, scope: {:batch, batch_id})
      |> put_flash(:error, "Batch action failed unexpectedly: #{inspect(reason)}")

    {:noreply, socket}
  end

  @impl true
  def handle_async({:batch_error_modal, request_key}, result, socket) do
    if socket.assigns.error_modal_request_key == request_key do
      case result do
        {:ok, {content, is_json}} ->
          {:noreply,
           socket
           |> assign(:error_modal_content, content)
           |> assign(:error_modal_is_json, is_json)
           |> assign(:error_modal_status, :ready)}

        {:exit, _reason} ->
          {:noreply, assign(socket, :error_modal_status, :error)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_details_section, :timeline, request_key}, {:ok, transitions}, socket) do
    if socket.assigns.batch.id == request_key and
         socket.assigns.timeline_request_key == request_key do
      {:noreply, assign(socket, transitions: transitions, timeline_status: :ready)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_details_section, :timeline, request_key}, {:exit, _reason}, socket) do
    if socket.assigns.batch.id == request_key and
         socket.assigns.timeline_request_key == request_key do
      {:noreply, assign(socket, :timeline_status, :error)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(
        {:batch_details_section, :delivery_stats, request_key},
        {:ok, delivery_stats},
        socket
      ) do
    if socket.assigns.batch.id == request_key and
         socket.assigns.delivery_stats_request_key == request_key do
      socket =
        socket
        |> assign(delivery_stats: delivery_stats, delivery_stats_status: :ready)
        |> assign(:delivery_stats_refresh_inflight, false)
        |> assign(:last_delivery_stats_refresh_at_ms, now_ms())

      socket =
        if socket.assigns.delivery_stats_dirty do
          maybe_schedule_delivery_stats_refresh(socket)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(
        {:batch_details_section, :delivery_stats, request_key},
        {:exit, _reason},
        socket
      ) do
    if socket.assigns.batch.id == request_key and
         socket.assigns.delivery_stats_request_key == request_key do
      socket =
        socket
        |> assign(:delivery_stats_status, :error)
        |> assign(:delivery_stats_refresh_inflight, false)
        |> assign(:last_delivery_stats_refresh_at_ms, now_ms())

      socket =
        if socket.assigns.delivery_stats_dirty do
          maybe_schedule_delivery_stats_refresh(socket)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_details_section, :capacity_info, request_key}, result, socket) do
    if request_key == socket.assigns.batch.id do
      case result do
        {:ok, capacity_info} ->
          {:noreply,
           socket
           |> assign(:capacity_info, capacity_info)
           |> assign(:capacity_info_status, :ready)
           |> assign(:capacity_info_stale, false)}

        {:exit, _reason} ->
          {:noreply, assign(socket, :capacity_info_status, :error)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_refresh, request_key}, {:ok, {:ok, batch}}, socket) do
    if socket.assigns.batch_refresh_request_key == request_key do
      {:noreply,
       socket
       |> assign(:batch, batch)
       |> mark_capacity_info_stale()
       |> start_timeline_load(batch.id)
       |> mark_delivery_stats_dirty()
       |> maybe_schedule_delivery_stats_refresh()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_refresh, request_key}, _result, socket) do
    if socket.assigns.batch_refresh_request_key == request_key do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: batch}},
        socket
      ) do
    request_key = {:batch_refresh, batch.id, System.unique_integer([:positive])}

    {:noreply,
     socket
     |> assign(:batch_refresh_request_key, request_key)
     |> start_async({:batch_refresh, request_key}, fn ->
       Batching.get_batch_by_id(batch.id)
     end)}
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

    {:noreply,
     socket
     |> assign(:batch, updated_batch)
     |> mark_capacity_info_stale()
     |> mark_delivery_stats_dirty()
     |> maybe_schedule_delivery_stats_refresh()}
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
       |> assign(batch: updated_batch)
       |> mark_capacity_info_stale()
       |> mark_delivery_stats_dirty()
       |> maybe_schedule_delivery_stats_refresh()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{topic: "ui_actions:batch:" <> _batch_id}, socket) do
    {:noreply, update(socket, :action_activity_version, &(&1 + 1))}
  end

  @impl true
  def handle_info(:refresh_delivery_stats, socket) do
    socket = assign(socket, :delivery_stats_refresh_scheduled, false)

    socket =
      cond do
        socket.assigns.delivery_stats_refresh_inflight ->
          socket

        not socket.assigns.delivery_stats_dirty ->
          socket

        true ->
          batch_id = socket.assigns.batch.id

          socket
          |> assign(:delivery_stats_dirty, false)
          |> assign(:delivery_stats_refresh_inflight, true)
          |> assign(:delivery_stats_request_key, batch_id)
          |> assign(
            :delivery_stats_status,
            next_section_status(socket.assigns.delivery_stats_status)
          )
          |> start_async({:batch_details_section, :delivery_stats, batch_id}, fn ->
            load_delivery_stats(batch_id)
          end)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:delivery_stats_fallback_tick, socket) do
    schedule_delivery_stats_fallback_tick()

    socket =
      if socket.assigns.batch.state in [
           :ready_to_deliver,
           :delivering,
           :partially_delivered,
           :delivery_failed
         ] do
        socket
        |> mark_delivery_stats_dirty()
        |> maybe_schedule_delivery_stats_refresh()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp start_current_batch_action_async(socket, action) do
    batch_id = socket.assigns.batch.id

    if pending_action?(socket.assigns.pending_actions, action, batch_id) do
      {:noreply, socket}
    else
      async_key = {:batch_action, action, batch_id}

      AsyncActions.start_shared_action(
        socket,
        async_key,
        fn -> perform_batch_action(action, batch_id) end,
        scope: {:batch, batch_id}
      )
    end
  end

  defp perform_batch_action(action, batch_id) do
    maybe_test_async_delay()

    case Batching.get_batch_by_id(batch_id) do
      {:ok, batch} ->
        case action do
          :upload ->
            case Batching.start_batch_upload(batch) do
              {:ok, _} ->
                {:ok, action, "Batch upload started"}

              {:error, error} ->
                {:error, format_generic_action_error("Failed to start upload", error)}
            end

          :cancel ->
            case Batching.cancel_batch(batch) do
              {:ok, _} -> {:ok, action, "Batch cancelled successfully"}
              {:error, error} -> {:error, format_cancel_error(error)}
            end

          :delete ->
            case Batching.destroy_batch(batch) do
              :ok -> {:ok, action, "Batch deleted successfully"}
              {:error, _} -> {:error, "Failed to delete batch"}
            end

          :restart ->
            case Batching.restart_batch(batch) do
              {:ok, _} ->
                {:ok, action, "Batch restart initiated successfully"}

              {:error, error} ->
                {:error, format_generic_action_error("Failed to restart batch", error)}
            end

          :redeliver ->
            case Batching.redeliver_batch(batch_id) do
              {:ok, _} ->
                {:ok, action, "Redelivery initiated for failed requests"}

              {:error, error} ->
                {:error, format_generic_action_error("Failed to redeliver", error)}
            end
        end

      {:error, _} ->
        {:error, "Batch not found"}
    end
  end

  def pending_action?(pending_actions, action, batch_id) do
    key = {:batch_action, action, batch_id}
    AsyncActions.pending?(pending_actions, key) or ActionActivity.active?(key)
  end

  defp start_section_loads(socket, batch_id) do
    socket
    |> start_timeline_load(batch_id)
    |> assign(:delivery_stats_request_key, batch_id)
    |> assign(:delivery_stats_refresh_inflight, true)
    |> assign(:delivery_stats_dirty, false)
    |> assign(:delivery_stats_refresh_scheduled, false)
    |> assign(:delivery_stats_status, next_section_status(socket.assigns.delivery_stats_status))
    |> start_async({:batch_details_section, :delivery_stats, batch_id}, fn ->
      load_delivery_stats(batch_id)
    end)
  end

  defp next_section_status(current) do
    if current in [:idle, :loading_initial], do: :loading_initial, else: :refreshing
  end

  defp start_timeline_load(socket, batch_id) do
    socket
    |> assign(:timeline_request_key, batch_id)
    |> assign(:timeline_status, next_section_status(socket.assigns.timeline_status))
    |> start_async({:batch_details_section, :timeline, batch_id}, fn ->
      load_transitions(batch_id)
    end)
  end

  defp load_transitions(batch_id) do
    batch = Batching.get_batch_by_id!(batch_id, load: [:transitions])
    Enum.sort_by(batch.transitions, & &1.transitioned_at, DateTime)
  end

  defp load_delivery_stats(batch_id) do
    batch = Batching.get_batch_by_id!(batch_id, load: [:delivery_stats])
    batch.delivery_stats || %{}
  end

  defp maybe_load_capacity_info(socket) do
    batch = socket.assigns.batch

    if socket.assigns.batch.state == :waiting_for_capacity and
         (is_nil(socket.assigns.capacity_info) or socket.assigns.capacity_info_stale) do
      socket
      |> assign(
        :capacity_info_status,
        if(is_nil(socket.assigns.capacity_info), do: :loading_initial, else: :refreshing)
      )
      |> start_async({:batch_details_section, :capacity_info, batch.id}, fn ->
        build_capacity_info(batch)
      end)
    else
      socket
    end
  end

  defp mark_capacity_info_stale(socket), do: assign(socket, :capacity_info_stale, true)

  defp build_capacity_info(batch) do
    {:ok, %{limit: limit, source: limit_source}} =
      Batcher.Clients.OpenAI.RateLimits.get_batch_limit_tokens(batch.model)

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

  defp format_cancel_error(error) do
    case error do
      %Ash.Error.Invalid{errors: errors} ->
        Enum.map_join(errors, ", ", fn e ->
          case e do
            %AshStateMachine.Errors.NoMatchingTransition{
              old_state: old_state,
              target: target
            } ->
              "Cannot transition batch from #{old_state} to #{target} state"

            _ ->
              Exception.message(e)
          end
        end)

      other ->
        "Failed to cancel batch: #{Exception.message(other)}"
    end
  end

  defp format_generic_action_error(prefix, error) do
    case error do
      %Ash.Error.Invalid{errors: errors} ->
        Enum.map_join(errors, ", ", &Exception.message/1)

      other ->
        "#{prefix}: #{Exception.message(other)}"
    end
  end

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

  def loading_section?(status), do: status in [:loading_initial, :refreshing]

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

  defp maybe_test_async_delay do
    case Application.get_env(:batcher, :batch_action_test_delay_ms, 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  defp mark_delivery_stats_dirty(socket), do: assign(socket, :delivery_stats_dirty, true)

  defp maybe_schedule_delivery_stats_refresh(socket) do
    cond do
      socket.assigns.delivery_stats_refresh_inflight ->
        socket

      socket.assigns.delivery_stats_refresh_scheduled ->
        socket

      not socket.assigns.delivery_stats_dirty ->
        socket

      true ->
        elapsed = now_ms() - socket.assigns.last_delivery_stats_refresh_at_ms
        delay_ms = max(@delivery_stats_refresh_throttle_ms - elapsed, 0)
        Process.send_after(self(), :refresh_delivery_stats, delay_ms)
        assign(socket, :delivery_stats_refresh_scheduled, true)
    end
  end

  defp schedule_delivery_stats_fallback_tick do
    Process.send_after(self(), :delivery_stats_fallback_tick, @delivery_stats_fallback_poll_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
