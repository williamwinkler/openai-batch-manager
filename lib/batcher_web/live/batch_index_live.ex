defmodule BatcherWeb.BatchIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias BatcherWeb.Live.Utils.ActionActivity
  alias BatcherWeb.Live.Utils.AsyncActions
  alias BatcherWeb.Live.Utils.AsyncPagination
  alias Batcher.Utils.Format
  @default_reload_coalesce_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to batch creation events
    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:created")
      BatcherWeb.Endpoint.subscribe("requests:created")
      BatcherWeb.Endpoint.subscribe("batches:metrics_delta")
    end

    socket =
      socket
      |> assign(:page_title, "Batches")
      |> assign(:subscribed_batch_ids, MapSet.new())
      |> assign(:visible_batch_ids, MapSet.new())
      |> assign(:reload_coalesce_ms, reload_coalesce_ms())
      |> assign(:reload_coalesce_timer_ref, nil)
      |> assign(:reload_scheduled?, false)
      |> assign(:reload_scheduled_refresh_count?, false)
      |> assign(:reload_inflight?, false)
      |> assign(:reload_pending?, false)
      |> assign(:reload_pending_refresh_count?, false)
      |> assign(:reload_pending_reasons, MapSet.new())
      |> assign(:last_reload_reason, nil)
      |> assign(:batch_index_reload_request_key, nil)
      |> assign(:pending_actions, MapSet.new())
      |> assign(:action_activity_version, 0)
      |> assign(:page_limit, 20)
      |> assign(:cursor_after, nil)
      |> assign(:cursor_before, nil)
      |> assign(:processing_since_by_batch_id, %{})
      |> assign(:processing_since_status, :idle)
      |> assign(:processing_since_request_key, nil)
      |> AsyncPagination.init()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    if Map.has_key?(params, "offset") do
      compat_params =
        [
          q: Map.get(params, "q", ""),
          sort_by: Map.get(params, "sort_by") |> validate_sort_by(),
          limit: parse_limit(Map.get(params, "limit"), 20)
        ]
        |> remove_empty()

      {:noreply, push_patch(socket, to: ~p"/batches?#{compat_params}")}
    else
      query_text = Map.get(params, "q", "")
      sort_by = Map.get(params, "sort_by") |> validate_sort_by()
      page_opts = keyset_page_opts(params, 20)

      socket =
        socket
        |> reset_reload_pipeline()
        |> assign(:query_text, query_text)
        |> assign(:sort_by, sort_by)
        |> assign(:page_limit, page_opts[:limit])
        |> assign(:cursor_after, page_opts[:after])
        |> assign(:cursor_before, page_opts[:before])
        |> apply_reloaded_page(
          fetch_batches_page(
            query_text,
            sort_by,
            page_opts[:limit],
            page_opts[:after],
            page_opts[:before]
          ),
          refresh_count?: true
        )

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    params =
      [
        q: query,
        sort_by: socket.assigns.sort_by,
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply, push_patch(socket, to: ~p"/batches?#{params}")}
  end

  @impl true
  def handle_event("change-sort", %{"sort_by" => sort_by}, socket) do
    sort_by = validate_sort_by(sort_by)

    # Reset to first page when sorting changes - don't include offset/limit, let handle_params handle it
    params =
      [
        q: socket.assigns.query_text,
        sort_by: sort_by,
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply, push_patch(socket, to: ~p"/batches?#{params}")}
  end

  @impl true
  def handle_event("upload_batch", %{"id" => id}, socket),
    do: start_batch_action_async(socket, :upload, id)

  @impl true
  def handle_event("cancel_batch", %{"id" => id}, socket),
    do: start_batch_action_async(socket, :cancel, id)

  @impl true
  def handle_event("delete_batch", %{"id" => id}, socket),
    do: start_batch_action_async(socket, :delete, id)

  @impl true
  def handle_event("restart_batch", %{"id" => id}, socket),
    do: start_batch_action_async(socket, :restart, id)

  @impl true
  def handle_event("redeliver_batch", %{"id" => id}, socket),
    do: start_batch_action_async(socket, :redeliver, id)

  @impl true
  def handle_async({:batch_action, action, batch_id}, {:ok, result}, socket) do
    key = {:batch_action, action, batch_id}
    socket = AsyncActions.clear_shared_pending(socket, key, scope: {:batch, batch_id})

    case result do
      {:ok, info_message, opts} ->
        socket =
          socket
          |> put_flash(:info, info_message)
          |> maybe_reload(Keyword.get(opts, :reload?, false))

        {:noreply, socket}

      {:error, error_message, _opts} ->
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
  def handle_async({:page_count, count_request_key}, result, socket) do
    {:noreply, AsyncPagination.handle_count_async(socket, count_request_key, result)}
  end

  @impl true
  def handle_async({:batch_processing_since, request_key}, result, socket) do
    if socket.assigns.processing_since_request_key == request_key do
      case result do
        {:ok, loaded_map} ->
          {:noreply,
           socket
           |> assign(:processing_since_by_batch_id, merge_processing_since(socket, loaded_map))
           |> assign(:processing_since_status, :ready)}

        {:exit, _reason} ->
          {:noreply, assign(socket, :processing_since_status, :error)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_index_reload, request_key}, {:ok, result}, socket) do
    if socket.assigns.batch_index_reload_request_key == request_key do
      socket =
        socket
        |> assign(:reload_inflight?, false)
        |> assign(:batch_index_reload_request_key, nil)

      socket =
        case result do
          {:ok, page, reload_opts} ->
            socket
            |> apply_reloaded_page(page, reload_opts)
            |> assign(:last_reload_reason, reload_opts[:reason])

          {:error, _reason} ->
            socket
        end

      {:noreply, maybe_run_pending_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:batch_index_reload, request_key}, {:exit, _reason}, socket) do
    if socket.assigns.batch_index_reload_request_key == request_key do
      socket =
        socket
        |> assign(:reload_inflight?, false)
        |> assign(:batch_index_reload_request_key, nil)

      {:noreply, maybe_run_pending_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "batches:state_changed:" <> batch_id, payload: %{data: _batch}},
        socket
      ) do
    if topic_batch_id_visible?(socket, batch_id) do
      {:noreply, request_reload(socket, :state_changed_visible_batch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{topic: "batches:created", payload: %{data: _batch}}, socket) do
    if top_of_feed_sensitive?(socket) do
      {:noreply, request_reload(socket, :batch_created_first_page)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{topic: "batches:created:" <> _batch_id, payload: %{data: _batch}}, socket) do
    if top_of_feed_sensitive?(socket) do
      {:noreply, request_reload(socket, :batch_created_first_page)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{topic: "batches:destroyed:" <> batch_id, payload: %{data: _batch}}, socket) do
    if topic_batch_id_visible?(socket, batch_id) do
      {:noreply, request_reload(socket, :destroyed_visible_batch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "requests:created", payload: %{data: request}},
        socket
      ) do
    if MapSet.member?(socket.assigns.visible_batch_ids, request.batch_id) do
      {:noreply, request_reload(socket, :request_created_visible_batch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "requests:created:" <> _request_id, payload: %{data: request}},
        socket
      ) do
    if MapSet.member?(socket.assigns.visible_batch_ids, request.batch_id) do
      {:noreply, request_reload(socket, :request_created_visible_batch)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{topic: "batches:metrics_delta", payload: payload},
        socket
      ) do
    {:noreply, apply_batch_metrics_delta(socket, payload)}
  end

  @impl true
  def handle_info(
        %{topic: "batches:progress_updated:" <> _batch_id, payload: %{data: batch}},
        socket
      ) do
    {:noreply, apply_batch_progress_update(socket, batch)}
  end

  @impl true
  def handle_info(%{topic: "ui_actions:batch:" <> _batch_id}, socket) do
    {:noreply, update(socket, :action_activity_version, &(&1 + 1))}
  end

  @impl true
  def handle_info(:run_coalesced_reload, socket) do
    refresh_count? = socket.assigns.reload_scheduled_refresh_count?

    socket =
      socket
      |> assign(:reload_coalesce_timer_ref, nil)
      |> assign(:reload_scheduled?, false)
      |> assign(:reload_scheduled_refresh_count?, false)
      |> maybe_start_reload_async(refresh_count?: refresh_count?)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp fetch_batches_page(query_text, sort_by, page_limit, cursor_after, cursor_before) do
    Batching.search_batches!(query_text,
      page: keyset_page_opts_from_assigns(page_limit, cursor_after, cursor_before),
      query: [sort_input: sort_by]
    )
  end

  defp apply_reloaded_page(socket, page, opts) do
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"

    socket =
      socket
      |> assign(:page, page)
      |> sync_batch_subscriptions(page.results)
      |> schedule_processing_since(query_text, sort_by, page)

    if Keyword.get(opts, :refresh_count?, true) do
      schedule_count(socket, query_text, sort_by)
    else
      socket
    end
  end

  defp schedule_count(socket, query_text, sort_by) do
    count_request_key = {:batches_count, query_text, sort_by}

    AsyncPagination.schedule_count(socket, count_request_key, fn ->
      count_batches(query_text)
    end)
  end

  defp schedule_processing_since(socket, query_text, sort_by, page) do
    ids = Enum.map(page.results, & &1.id)

    request_key =
      {:processing_since, query_text, sort_by, socket.assigns.cursor_after,
       socket.assigns.cursor_before, page.limit, ids}

    socket =
      socket
      |> assign(:processing_since_request_key, request_key)
      |> assign(
        :processing_since_status,
        if(socket.assigns.processing_since_status in [:idle],
          do: :loading_initial,
          else: :refreshing
        )
      )

    if connected?(socket) do
      start_async(socket, {:batch_processing_since, request_key}, fn ->
        load_processing_since(ids)
      end)
    else
      socket
    end
  end

  defp load_processing_since(ids) do
    case Batching.list_batches_by_ids(ids, load: [:processing_since]) do
      {:ok, batches} ->
        batches
        |> Enum.map(fn batch -> {batch.id, batch.processing_since} end)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  defp merge_processing_since(socket, loaded_map) do
    visible_ids = socket.assigns.page.results |> Enum.map(& &1.id) |> MapSet.new()
    existing = socket.assigns.processing_since_by_batch_id

    kept_existing =
      existing
      |> Enum.filter(fn {id, _} -> MapSet.member?(visible_ids, id) end)
      |> Map.new()

    Map.merge(kept_existing, loaded_map)
  end

  defp count_batches(query_text) do
    case Batching.count_batches_for_search(query_text, page: [limit: 1, count: true]) do
      {:ok, page} -> {:ok, page.count || 0}
      {:error, error} -> {:error, error}
    end
  end

  defp start_batch_action_async(socket, action, raw_id) do
    case parse_batch_id(raw_id) do
      {:ok, batch_id} ->
        key = {:batch_action, action, batch_id}

        AsyncActions.start_shared_action(
          socket,
          key,
          fn -> perform_batch_action(action, batch_id) end,
          scope: {:batch, batch_id}
        )

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid batch id")}
    end
  end

  defp perform_batch_action(action, batch_id) do
    maybe_test_async_delay()

    case action do
      :upload -> perform_upload(batch_id)
      :cancel -> perform_cancel(batch_id)
      :delete -> perform_delete(batch_id)
      :restart -> perform_restart(batch_id)
      :redeliver -> perform_redeliver(batch_id)
    end
  end

  defp perform_upload(batch_id) do
    case Batching.get_batch_by_id(batch_id) do
      {:ok, batch} ->
        if batch.state == :building do
          case Batcher.Batching.BatchBuilder.upload_batch(batch.url, batch.model) do
            :ok ->
              {:ok, "Batch upload initiated successfully", reload?: false}

            {:error, reason} ->
              error_msg =
                case reason do
                  :noproc ->
                    "BatchBuilder not found. The batch may have already been uploaded."

                  :no_building_batch ->
                    "No batch in building state found for this model/endpoint."

                  other ->
                    "Failed to upload batch: #{inspect(other)}"
                end

              {:error, error_msg, reload?: false}
          end
        else
          {:error, "Batch is not in building state", reload?: false}
        end

      {:error, _} ->
        {:error, "Batch not found", reload?: false}
    end
  end

  defp perform_cancel(batch_id) do
    with {:ok, batch} <- Batching.get_batch_by_id(batch_id) do
      case Batching.cancel_batch(batch) do
        {:ok, _} ->
          {:ok, "Batch cancelled successfully", reload?: true}

        {:error, error} ->
          {:error, format_cancel_error(error), reload?: false}
      end
    else
      {:error, _} -> {:error, "Batch not found", reload?: false}
    end
  end

  defp perform_delete(batch_id) do
    with {:ok, batch} <- Batching.get_batch_by_id(batch_id) do
      case Batching.destroy_batch(batch) do
        :ok -> {:ok, "Batch deleted successfully", reload?: true}
        {:ok, _} -> {:ok, "Batch deleted successfully", reload?: true}
        {:error, _} -> {:error, "Failed to delete batch", reload?: false}
      end
    else
      {:error, _} -> {:error, "Batch not found", reload?: false}
    end
  end

  defp perform_restart(batch_id) do
    with {:ok, batch} <- Batching.get_batch_by_id(batch_id) do
      case Batching.restart_batch(batch) do
        {:ok, _} ->
          {:ok, "Batch restart initiated successfully", reload?: true}

        {:error, error} ->
          {:error, format_generic_action_error("Failed to restart batch", error), reload?: false}
      end
    else
      {:error, _} -> {:error, "Batch not found", reload?: false}
    end
  end

  defp perform_redeliver(batch_id) do
    case Batching.redeliver_batch(batch_id) do
      {:ok, _} ->
        {:ok, "Redelivery initiated for failed requests", reload?: true}

      {:error, error} ->
        {:error, format_generic_action_error("Failed to redeliver", error), reload?: false}
    end
  end

  defp maybe_reload(socket, true),
    do: reload_now(socket, reason: :action_outcome, refresh_count?: true)

  defp maybe_reload(socket, false), do: socket

  def pending_action?(pending_actions, action, batch_id) do
    key = {:batch_action, action, batch_id}
    AsyncActions.pending?(pending_actions, key) or ActionActivity.active?(key)
  end

  defp parse_batch_id(raw_id) when is_binary(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_batch_id(_), do: :error

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

  defp maybe_test_async_delay do
    case Application.get_env(:batcher, :batch_action_test_delay_ms, 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  defp request_reload(socket, reason) do
    socket =
      socket
      |> update(:reload_pending_reasons, &MapSet.put(&1, reason))
      |> assign(:last_reload_reason, reason)

    cond do
      socket.assigns.reload_inflight? ->
        socket
        |> assign(:reload_pending?, true)
        |> assign(:reload_pending_refresh_count?, socket.assigns.reload_pending_refresh_count?)

      socket.assigns.reload_scheduled? ->
        socket

      true ->
        schedule_reload_timer(socket, socket.assigns.reload_coalesce_ms, refresh_count?: false)
    end
  end

  defp reload_now(socket, opts) do
    refresh_count? = Keyword.get(opts, :refresh_count?, true)
    reason = Keyword.get(opts, :reason, :manual)

    socket =
      socket
      |> update(:reload_pending_reasons, &MapSet.put(&1, reason))
      |> assign(:last_reload_reason, reason)

    cond do
      socket.assigns.reload_inflight? ->
        socket
        |> assign(:reload_pending?, true)
        |> assign(
          :reload_pending_refresh_count?,
          socket.assigns.reload_pending_refresh_count? or refresh_count?
        )

      socket.assigns.reload_scheduled? ->
        socket
        |> cancel_scheduled_reload()
        |> perform_reload_now(refresh_count?: refresh_count?, reason: reason)

      true ->
        perform_reload_now(socket, refresh_count?: refresh_count?, reason: reason)
    end
  end

  defp perform_reload_now(socket, opts) do
    refresh_count? = Keyword.get(opts, :refresh_count?, true)
    reason = Keyword.get(opts, :reason, :manual)

    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"
    page_limit = socket.assigns[:page_limit] || 20
    cursor_after = socket.assigns[:cursor_after]
    cursor_before = socket.assigns[:cursor_before]

    page = fetch_batches_page(query_text, sort_by, page_limit, cursor_after, cursor_before)

    socket
    |> apply_reloaded_page(page, refresh_count?: refresh_count?)
    |> assign(:last_reload_reason, reason)
  end

  defp schedule_reload_timer(socket, delay_ms, opts) do
    timer_ref = Process.send_after(self(), :run_coalesced_reload, delay_ms)

    socket
    |> assign(:reload_coalesce_timer_ref, timer_ref)
    |> assign(:reload_scheduled?, true)
    |> assign(:reload_scheduled_refresh_count?, Keyword.get(opts, :refresh_count?, false))
  end

  defp maybe_start_reload_async(socket, opts) do
    if socket.assigns.reload_inflight? do
      socket
    else
      reason = socket.assigns.last_reload_reason
      refresh_count? = Keyword.get(opts, :refresh_count?, false)
      request_key = {:batch_index_reload, System.unique_integer([:positive])}

      query_text = socket.assigns[:query_text] || ""
      sort_by = socket.assigns[:sort_by] || "-created_at"
      page_limit = socket.assigns[:page_limit] || 20
      cursor_after = socket.assigns[:cursor_after]
      cursor_before = socket.assigns[:cursor_before]

      socket
      |> assign(:reload_inflight?, true)
      |> assign(:batch_index_reload_request_key, request_key)
      |> start_async({:batch_index_reload, request_key}, fn ->
        maybe_test_reload_delay()

        page = fetch_batches_page(query_text, sort_by, page_limit, cursor_after, cursor_before)
        {:ok, page, [refresh_count?: refresh_count?, reason: reason]}
      end)
    end
  end

  defp maybe_run_pending_reload(socket) do
    if socket.assigns.reload_pending? do
      refresh_count? = socket.assigns.reload_pending_refresh_count?

      socket
      |> assign(:reload_pending?, false)
      |> assign(:reload_pending_refresh_count?, false)
      |> schedule_reload_timer(0, refresh_count?: refresh_count?)
    else
      socket
    end
  end

  defp reset_reload_pipeline(socket) do
    socket
    |> cancel_scheduled_reload()
    |> assign(:reload_inflight?, false)
    |> assign(:reload_pending?, false)
    |> assign(:reload_pending_refresh_count?, false)
    |> assign(:reload_pending_reasons, MapSet.new())
    |> assign(:batch_index_reload_request_key, nil)
  end

  defp cancel_scheduled_reload(socket) do
    maybe_cancel_coalesce_timer(socket.assigns[:reload_coalesce_timer_ref])

    socket
    |> assign(:reload_coalesce_timer_ref, nil)
    |> assign(:reload_scheduled?, false)
    |> assign(:reload_scheduled_refresh_count?, false)
  end

  defp maybe_cancel_coalesce_timer(nil), do: :ok
  defp maybe_cancel_coalesce_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp topic_batch_id_visible?(socket, batch_id_str) do
    case Integer.parse(batch_id_str) do
      {batch_id, ""} -> MapSet.member?(socket.assigns.visible_batch_ids, batch_id)
      _ -> false
    end
  end

  defp top_of_feed_sensitive?(socket) do
    query_text = (socket.assigns[:query_text] || "") |> String.trim()

    socket.assigns[:sort_by] == "-created_at" and
      is_nil(socket.assigns[:cursor_after]) and
      is_nil(socket.assigns[:cursor_before]) and
      query_text == ""
  end

  defp reload_coalesce_ms do
    case Application.get_env(:batcher, :ui_batch_reload_coalesce_ms, @default_reload_coalesce_ms) do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_reload_coalesce_ms
    end
  end

  defp maybe_test_reload_delay do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test do
      case Application.get_env(:batcher, :batch_index_reload_delay_ms, 0) do
        delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
        _ -> :ok
      end
    end
  end

  defp apply_batch_metrics_delta(
         socket,
         %{
           batch_id: batch_id,
           request_count_delta: request_count_delta,
           size_bytes_delta: size_bytes_delta
         } =
           payload
       ) do
    estimated_input_tokens_delta = Map.get(payload, :estimated_input_tokens_delta, 0)

    estimated_request_input_tokens_delta =
      Map.get(payload, :estimated_request_input_tokens_delta, 0)

    page = socket.assigns.page

    updated_results =
      Enum.map(page.results, fn batch ->
        if batch.id == batch_id do
          %{
            batch
            | request_count: (batch.request_count || 0) + request_count_delta,
              size_bytes: (batch.size_bytes || 0) + size_bytes_delta,
              estimated_input_tokens_total:
                (batch.estimated_input_tokens_total || 0) + estimated_input_tokens_delta,
              estimated_request_input_tokens_total:
                (batch.estimated_request_input_tokens_total || 0) +
                  estimated_request_input_tokens_delta
          }
        else
          batch
        end
      end)

    assign(socket, :page, %{page | results: updated_results})
  end

  defp apply_batch_metrics_delta(socket, _payload), do: socket

  defp apply_batch_progress_update(socket, batch_data) do
    page = socket.assigns.page

    updated_results =
      Enum.map(page.results, fn batch ->
        if batch.id == batch_data.id do
          %{
            batch
            | openai_requests_completed: batch_data.openai_requests_completed,
              openai_requests_failed: batch_data.openai_requests_failed,
              openai_requests_total: batch_data.openai_requests_total
          }
        else
          batch
        end
      end)

    assign(socket, :page, %{page | results: updated_results})
  end

  defp sync_batch_subscriptions(socket, batches) do
    if connected?(socket) do
      new_visible_ids = batches |> Enum.map(& &1.id) |> MapSet.new()
      subscribed_ids = socket.assigns.subscribed_batch_ids
      old_visible_ids = socket.assigns.visible_batch_ids

      to_subscribe =
        new_visible_ids
        |> Enum.reject(&MapSet.member?(subscribed_ids, &1))

      to_unsubscribe =
        old_visible_ids
        |> Enum.reject(&MapSet.member?(new_visible_ids, &1))

      Enum.each(to_subscribe, fn id ->
        BatcherWeb.Endpoint.subscribe("batches:state_changed:#{id}")
        BatcherWeb.Endpoint.subscribe("batches:destroyed:#{id}")
        BatcherWeb.Endpoint.subscribe("batches:progress_updated:#{id}")
        ActionActivity.subscribe({:batch, id})
      end)

      Enum.each(to_unsubscribe, fn id ->
        BatcherWeb.Endpoint.unsubscribe("batches:state_changed:#{id}")
        BatcherWeb.Endpoint.unsubscribe("batches:destroyed:#{id}")
        BatcherWeb.Endpoint.unsubscribe("batches:progress_updated:#{id}")
        ActionActivity.unsubscribe({:batch, id})
      end)

      updated_subscribed_ids =
        subscribed_ids
        |> MapSet.difference(MapSet.new(to_unsubscribe))
        |> MapSet.union(MapSet.new(to_subscribe))

      socket
      |> assign(:subscribed_batch_ids, updated_subscribed_ids)
      |> assign(:visible_batch_ids, new_visible_ids)
    else
      socket
    end
  end

  defp status_duration(batch, processing_since_by_batch_id) do
    datetime =
      case batch.state do
        :waiting_for_capacity -> batch.waiting_for_capacity_since_at
        :openai_processing -> Map.get(processing_since_by_batch_id, batch.id)
        :uploading -> batch.updated_at
        :downloading -> batch.updated_at
        :delivering -> batch.updated_at
        _ -> nil
      end

    duration = Format.duration_since(datetime)
    ratio = openai_progress_ratio(batch)

    cond do
      duration == "" and is_nil(ratio) -> ""
      duration == "" -> ratio
      is_nil(ratio) -> duration
      true -> "#{duration} (#{ratio})"
    end
  end

  defp openai_progress_ratio(batch) do
    total = batch.openai_requests_total
    completed = batch.openai_requests_completed || 0

    if is_integer(total) and total > 0 and is_integer(completed) do
      "#{completed}/#{total}"
    end
  end

  defp token_limit_backoff_waiting?(batch) do
    batch.state == :waiting_for_capacity and
      batch.capacity_wait_reason == "token_limit_exceeded_backoff"
  end

  defp token_limit_next_retry_title(nil), do: nil

  defp token_limit_next_retry_title(next_at) do
    "Next retry #{Calendar.strftime(next_at, "%d %b %Y, %H:%M UTC")}"
  end

  def loading_processing_since?(status), do: status in [:loading_initial, :refreshing]

  defp sort_options do
    [
      {"Newest first", "-created_at"},
      {"Oldest first", "created_at"}
    ]
  end

  defp validate_sort_by(key) when is_binary(key) do
    valid_keys = Enum.map(sort_options(), &elem(&1, 1))

    if key in valid_keys do
      key
    else
      List.first(valid_keys)
    end
  end

  defp validate_sort_by(_), do: "-created_at"

  defp remove_empty(params) do
    Enum.filter(params, fn {_key, val} ->
      case val do
        "" -> false
        nil -> false
        _ -> true
      end
    end)
  end

  defp sort_changer(assigns) do
    assigns = assign(assigns, :options, sort_options())

    ~H"""
    <form phx-change="change-sort" class="flex items-center gap-2">
      <label for="sort_by" class="text-sm text-base-content/70 whitespace-nowrap">Sort by:</label>
      <select
        id="sort_by"
        name="sort_by"
        class="select select-bordered w-auto min-w-[180px] text-sm bg-base-200 border-base-300"
      >
        {Phoenix.HTML.Form.options_for_select(@options, @selected)}
      </select>
    </form>
    """
  end

  defp search_box(assigns) do
    ~H"""
    <form class="relative flex items-center" phx-change="search" phx-submit="search">
      <.icon
        name="hero-magnifying-glass"
        class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/50 pointer-events-none z-10"
      />
      <label for="search-query" class="hidden">Search</label>
      <input
        type="text"
        name="query"
        id="search-query"
        phx-debounce="300"
        value={@query}
        placeholder="Search model or endpoint..."
        class="input pl-10 w-64 text-sm bg-base-200 border-base-300"
      />
    </form>
    """
  end

  defp keyset_page_opts(params, default_limit) do
    limit = parse_limit(Map.get(params, "limit"), default_limit)
    after_cursor = blank_to_nil(Map.get(params, "after"))
    before_cursor = blank_to_nil(Map.get(params, "before"))
    keyset_page_opts_from_assigns(limit, after_cursor, before_cursor)
  end

  defp keyset_page_opts_from_assigns(limit, after_cursor, before_cursor) do
    [limit: limit, count: false]
    |> maybe_put_cursor(:after, after_cursor)
    |> maybe_put_cursor(:before, before_cursor)
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default)
      _ -> default
    end
  end

  defp parse_limit(limit, _default) when is_integer(limit) do
    limit
    |> max(1)
    |> min(100)
  end

  defp parse_limit(_limit, default), do: default

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put_cursor(opts, _key, nil), do: opts
  defp maybe_put_cursor(opts, key, value), do: Keyword.put(opts, key, value)
end
