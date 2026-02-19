defmodule BatcherWeb.BatchIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias BatcherWeb.Live.Utils.AsyncActions
  alias BatcherWeb.Live.Utils.ActionLocks
  alias BatcherWeb.Live.Utils.AsyncPagination
  alias Batcher.Utils.Format
  @reload_debounce_ms 750

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
      |> assign(:reload_timer_ref, nil)
      |> assign(:pending_actions, MapSet.new())
      |> assign(:processing_since_by_batch_id, %{})
      |> assign(:processing_since_status, :idle)
      |> assign(:processing_since_request_key, nil)
      |> AsyncPagination.init()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query_text = Map.get(params, "q", "")
    sort_by = Map.get(params, "sort_by") |> validate_sort_by()

    page_opts =
      AshPhoenix.LiveView.params_to_page_opts(params, default_limit: 20)
      |> Keyword.put(:count, false)

    page =
      Batching.search_batches!(query_text,
        page: page_opts,
        query: [sort_input: sort_by]
      )

    socket =
      socket
      |> assign(:query_text, query_text)
      |> assign(:sort_by, sort_by)
      |> assign(:page, page)
      |> subscribe_to_batches(page.results)
      |> schedule_processing_since(query_text, sort_by, page)
      |> schedule_count(query_text, sort_by)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    params =
      [
        q: query,
        sort_by: socket.assigns.sort_by
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
        sort_by: sort_by
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
    ActionLocks.release({:batch_action, action, batch_id})
    socket = AsyncActions.clear_pending(socket, {:batch_action, action, batch_id})

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
    ActionLocks.release({:batch_action, action, batch_id})

    socket =
      socket
      |> AsyncActions.clear_pending({:batch_action, action, batch_id})
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
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: _batch}},
        socket
      ) do
    # Reload the page to reflect state changes
    {:noreply, reload_page(socket, refresh_count?: false)}
  end

  @impl true
  def handle_info(%{topic: "batches:created", payload: %{data: _batch}}, socket) do
    # Reload batches to include the new one (respects current filters/sort)
    {:noreply, reload_page(socket, refresh_count?: false)}
  end

  @impl true
  def handle_info(%{topic: "batches:created:" <> _batch_id, payload: %{data: _batch}}, socket) do
    # Also handle individual batch creation events
    {:noreply, reload_page(socket, refresh_count?: false)}
  end

  @impl true
  def handle_info(%{topic: "batches:destroyed:" <> _batch_id, payload: %{data: _batch}}, socket) do
    {:noreply, reload_page(socket, refresh_count?: false)}
  end

  @impl true
  def handle_info(
        %{topic: "requests:created", payload: %{data: request}},
        socket
      ) do
    # Check if the request belongs to any batch on the current page
    batch_ids_on_page = Enum.map(socket.assigns.page.results, & &1.id)

    if request.batch_id in batch_ids_on_page do
      # Fallback for missed delta events
      {:noreply, schedule_reload(socket)}
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
    batch_ids_on_page = Enum.map(socket.assigns.page.results, & &1.id)

    if request.batch_id in batch_ids_on_page do
      {:noreply, schedule_reload(socket)}
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
  def handle_info(:reload_page_debounced, socket) do
    {:noreply, socket |> assign(:reload_timer_ref, nil) |> reload_page(refresh_count?: false)}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp reload_page(socket, opts) do
    maybe_cancel_timer(socket.assigns[:reload_timer_ref])

    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"

    page =
      Batching.search_batches!(query_text,
        page: [offset: socket.assigns.page.offset, limit: socket.assigns.page.limit, count: false],
        query: [sort_input: sort_by]
      )

    socket =
      socket
      |> assign(:reload_timer_ref, nil)
      |> assign(:page, page)
      |> subscribe_to_batches(page.results)
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
    request_key = {:processing_since, query_text, sort_by, page.offset, page.limit, ids}

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
    ids
    |> Enum.map(fn id ->
      case Batching.get_batch_by_id(id, load: [:processing_since]) do
        {:ok, batch} -> {id, batch.processing_since}
        _ -> {id, nil}
      end
    end)
    |> Map.new()
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

        if pending_action?(socket.assigns.pending_actions, action, batch_id) do
          {:noreply, socket}
        else
          if ActionLocks.acquire(key) do
            AsyncActions.start_action(socket, key, fn ->
              perform_batch_action(action, batch_id)
            end)
          else
            {:noreply, socket}
          end
        end

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
          case Batcher.BatchBuilder.upload_batch(batch.url, batch.model) do
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

  defp maybe_reload(socket, true), do: reload_page(socket, refresh_count?: true)
  defp maybe_reload(socket, false), do: socket

  def pending_action?(pending_actions, action, batch_id) do
    key = {:batch_action, action, batch_id}
    AsyncActions.pending?(pending_actions, key) or ActionLocks.locked?(key)
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

  defp schedule_reload(socket) do
    maybe_cancel_timer(socket.assigns[:reload_timer_ref])
    timer_ref = Process.send_after(self(), :reload_page_debounced, @reload_debounce_ms)
    assign(socket, :reload_timer_ref, timer_ref)
  end

  defp maybe_cancel_timer(nil), do: :ok
  defp maybe_cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

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

  defp subscribe_to_batches(socket, batches) do
    if connected?(socket) do
      already_subscribed = socket.assigns.subscribed_batch_ids

      new_ids =
        batches
        |> Enum.map(& &1.id)
        |> Enum.reject(&MapSet.member?(already_subscribed, &1))

      Enum.each(new_ids, fn id ->
        BatcherWeb.Endpoint.subscribe("batches:state_changed:#{id}")
        BatcherWeb.Endpoint.subscribe("batches:destroyed:#{id}")
        BatcherWeb.Endpoint.subscribe("batches:progress_updated:#{id}")
      end)

      new_subscribed = Enum.reduce(new_ids, already_subscribed, &MapSet.put(&2, &1))
      assign(socket, :subscribed_batch_ids, new_subscribed)
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
        value={@query}
        placeholder="Search model or endpoint..."
        class="input pl-10 w-64 text-sm bg-base-200 border-base-300"
      />
    </form>
    """
  end
end
