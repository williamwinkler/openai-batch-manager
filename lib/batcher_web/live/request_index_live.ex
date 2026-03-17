defmodule BatcherWeb.RequestIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias BatcherWeb.Live.Utils.ActionActivity
  alias BatcherWeb.Live.Utils.AsyncActions
  alias BatcherWeb.Live.Utils.AsyncPagination
  alias Batcher.Utils.Format

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to request creation events
    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("requests:created")
      BatcherWeb.Endpoint.subscribe("requests:state_changed")
    end

    socket =
      socket
      |> assign(:page_title, "Requests")
      |> assign(:pending_actions, MapSet.new())
      |> assign(:action_activity_version, 0)
      |> assign(:pending_refresh_count, 0)
      |> assign(:pending_refresh_reasons, MapSet.new())
      |> assign(:last_event_at_ms, nil)
      |> assign(:visible_created_before, DateTime.utc_now())
      |> assign(:clear_pending_on_next_params?, false)
      |> assign(:page_limit, 25)
      |> assign(:state_filter, nil)
      |> assign(:cursor_after, nil)
      |> assign(:cursor_before, nil)
      |> AsyncPagination.init()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    if Map.has_key?(params, "offset") do
      compat_params =
        [
          q: Map.get(params, "q", ""),
          sort_by: Map.get(params, "sort_by"),
          batch_id: parse_batch_id(Map.get(params, "batch_id")),
          state: state_filter_param(parse_state_filter(Map.get(params, "state"))),
          limit: parse_limit(Map.get(params, "limit"), 25)
        ]
        |> remove_empty()

      {:noreply, push_patch(socket, to: ~p"/requests?#{compat_params}")}
    else
      query_text = Map.get(params, "q", "")
      sort_by_param = Map.get(params, "sort_by")
      batch_id = parse_batch_id(Map.get(params, "batch_id"))
      state_filter = parse_state_filter(Map.get(params, "state"))

      # If batch_id is present but sort_by is not "batch_filter", auto-select batch_filter
      # If batch_filter is selected but no batch_id, use default sort
      sort_by =
        cond do
          not is_nil(batch_id) and sort_by_param != "batch_filter" -> "batch_filter"
          is_nil(sort_by_param) -> "-created_at"
          true -> validate_sort_by(sort_by_param)
        end

      sort_input =
        if sort_by == "batch_filter" and is_nil(batch_id), do: "-created_at", else: sort_by

      page_opts = keyset_page_opts(params, 25)

      page =
        Batching.search_requests!(
          query_text,
          %{
            sort_input: sort_input,
            batch_id: batch_id,
            state_filter: state_filter,
            created_before: socket.assigns.visible_created_before
          },
          load: [:batch],
          page: page_opts
        )

      socket =
        socket
        |> assign(:query_text, query_text)
        |> assign(:sort_by, sort_by)
        |> assign(:batch_id, batch_id)
        |> assign(:state_filter, state_filter)
        |> assign(:page_limit, page_opts[:limit])
        |> assign(:cursor_after, page_opts[:after])
        |> assign(:cursor_before, page_opts[:before])
        |> assign(:page, page)
        |> maybe_clear_pending_refresh()
        |> schedule_count(
          query_text,
          sort_input,
          batch_id,
          state_filter,
          socket.assigns.visible_created_before
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
        batch_id: socket.assigns.batch_id,
        state: state_filter_param(socket.assigns.state_filter),
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply,
     socket
     |> mark_pending_clear_on_next_params()
     |> push_patch(to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("change-sort", %{"sort_by" => sort_by}, socket) do
    sort_by = validate_sort_by(sort_by)

    # If switching to batch filter, keep current batch_id if it exists
    # Otherwise, if switching away from batch filter, clear batch_id
    batch_id =
      if sort_by == "batch_filter" do
        socket.assigns.batch_id
      else
        nil
      end

    # Reset to first page when sorting changes - don't include offset/limit, let handle_params handle it
    params =
      [
        q: socket.assigns.query_text,
        sort_by: sort_by,
        batch_id: batch_id,
        state: state_filter_param(socket.assigns.state_filter),
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply,
     socket
     |> mark_pending_clear_on_next_params()
     |> push_patch(to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("change-batch-filter", %{"batch_id" => batch_id_str}, socket) do
    batch_id = parse_batch_id(batch_id_str)

    params =
      [
        q: socket.assigns.query_text,
        sort_by: socket.assigns.sort_by,
        batch_id: batch_id,
        state: state_filter_param(socket.assigns.state_filter),
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply,
     socket
     |> mark_pending_clear_on_next_params()
     |> push_patch(to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("clear_batch_filter", _params, socket) do
    params =
      [
        q: socket.assigns.query_text,
        sort_by: socket.assigns.sort_by,
        state: state_filter_param(socket.assigns.state_filter),
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply,
     socket
     |> mark_pending_clear_on_next_params()
     |> push_patch(to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("change-state-filter", %{"state" => state_param}, socket) do
    state_filter = parse_state_filter(state_param)

    params =
      [
        q: socket.assigns.query_text,
        sort_by: socket.assigns.sort_by,
        batch_id: socket.assigns.batch_id,
        state: state_filter_param(state_filter),
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply,
     socket
     |> mark_pending_clear_on_next_params()
     |> push_patch(to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("refresh_requests", _params, socket) do
    params =
      [
        q: socket.assigns.query_text,
        sort_by: socket.assigns.sort_by,
        batch_id: socket.assigns.batch_id,
        state: state_filter_param(socket.assigns.state_filter),
        limit: socket.assigns.page_limit
      ]
      |> remove_empty()

    {:noreply,
     socket
     |> assign(:visible_created_before, DateTime.utc_now())
     |> clear_pending_refresh()
     |> push_patch(to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("retry_delivery", %{"id" => request_id}, socket) do
    start_request_action_async(socket, :retry_delivery, request_id)
  end

  @impl true
  def handle_info(%{topic: "requests:created", payload: %{data: _request}}, socket) do
    {:noreply, buffer_pending_refresh(socket, :created)}
  end

  @impl true
  def handle_info(%{topic: "requests:state_changed", payload: %{data: _request}}, socket) do
    {:noreply, buffer_pending_refresh(socket, :state_changed)}
  end

  @impl true
  def handle_info(%{topic: "ui_actions:request:" <> _request_id}, socket) do
    {:noreply, update(socket, :action_activity_version, &(&1 + 1))}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_async({:page_count, count_request_key}, result, socket) do
    {:noreply, AsyncPagination.handle_count_async(socket, count_request_key, result)}
  end

  @impl true
  def handle_async({:request_action, action, request_id}, {:ok, result}, socket) do
    key = {:request_action, action, request_id}
    socket = AsyncActions.clear_shared_pending(socket, key, scope: {:request, request_id})

    case result do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> reload_page(refresh_count?: false)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_async({:request_action, action, request_id}, {:exit, reason}, socket) do
    key = {:request_action, action, request_id}

    {:noreply,
     socket
     |> AsyncActions.clear_shared_pending(key, scope: {:request, request_id})
     |> put_flash(:error, "Request action failed unexpectedly: #{inspect(reason)}")}
  end

  defp reload_page(socket, opts) do
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"
    batch_id = socket.assigns[:batch_id]
    state_filter = socket.assigns[:state_filter]
    page_limit = socket.assigns[:page_limit] || 25
    cursor_after = socket.assigns[:cursor_after]
    cursor_before = socket.assigns[:cursor_before]

    # If batch_filter is selected but no batch_id, use default sort
    sort_input =
      if sort_by == "batch_filter" and is_nil(batch_id), do: "-created_at", else: sort_by

    page =
      Batching.search_requests!(
        query_text,
        %{
          sort_input: sort_input,
          batch_id: batch_id,
          state_filter: state_filter,
          created_before: socket.assigns.visible_created_before
        },
        load: [:batch],
        page: keyset_page_opts_from_assigns(page_limit, cursor_after, cursor_before)
      )

    socket =
      socket
      |> assign(:page, page)

    if Keyword.get(opts, :refresh_count?, true) do
      schedule_count(
        socket,
        query_text,
        sort_input,
        batch_id,
        state_filter,
        socket.assigns.visible_created_before
      )
    else
      socket
    end
  end

  defp schedule_count(
         socket,
         query_text,
         sort_input,
         batch_id,
         state_filter,
         visible_created_before
       ) do
    count_request_key =
      {:requests_count, query_text, sort_input, batch_id, state_filter, visible_created_before}

    AsyncPagination.schedule_count(socket, count_request_key, fn ->
      count_requests(query_text, batch_id, state_filter, visible_created_before)
    end)
  end

  defp count_requests(query_text, batch_id, state_filter, visible_created_before) do
    maybe_test_count_delay(query_text)

    if maybe_test_count_error?(query_text) do
      {:error, :forced_count_error}
    else
      if use_estimated_count?(query_text, state_filter) do
        case estimate_count_from_batches(batch_id) do
          {:ok, count} ->
            {:ok, count}

          {:error, _reason} ->
            exact_count_requests(query_text, batch_id, state_filter, visible_created_before)
        end
      else
        exact_count_requests(query_text, batch_id, state_filter, visible_created_before)
      end
    end
  end

  defp exact_count_requests(query_text, batch_id, state_filter, visible_created_before) do
    case Batching.count_requests_for_search(
           query_text,
           %{
             batch_id: batch_id,
             state_filter: state_filter,
             created_before: visible_created_before
           },
           page: [limit: 1, count: true]
         ) do
      {:ok, page} -> {:ok, page.count || 0}
      {:error, error} -> {:error, error}
    end
  end

  defp use_estimated_count?(query_text, state_filter) do
    Application.get_env(:batcher, :request_index_use_estimated_counts, true) and
      query_text in [nil, ""] and is_nil(state_filter)
  end

  defp estimate_count_from_batches(nil) do
    case Batching.list_batches(query: [select: [:request_count]]) do
      {:ok, batches} ->
        total = Enum.reduce(batches, 0, fn batch, acc -> acc + (batch.request_count || 0) end)
        {:ok, total}

      {:error, error} ->
        {:error, error}
    end
  end

  defp estimate_count_from_batches(batch_id) when is_integer(batch_id) do
    case Batching.get_batch_by_id(batch_id) do
      {:ok, batch} -> {:ok, batch.request_count || 0}
      {:error, error} -> {:error, error}
    end
  end

  defp estimate_count_from_batches(_batch_id), do: {:error, :invalid_batch_id}

  defp maybe_test_count_delay(query_text) do
    if test_env?() do
      delay_map = Application.get_env(:batcher, :request_index_count_delay_ms_by_query, %{})
      delay_ms = Map.get(delay_map, query_text, 0)

      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end
    end
  end

  defp maybe_test_count_error?(query_text) do
    if test_env?() do
      error_queries = Application.get_env(:batcher, :request_index_count_error_queries, [])
      query_text in error_queries
    else
      false
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp start_request_action_async(socket, action, raw_request_id) do
    case parse_batch_id(raw_request_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Invalid request id")}

      request_id ->
        key = {:request_action, action, request_id}

        AsyncActions.start_shared_action(
          socket,
          key,
          fn -> perform_request_action(action, request_id) end,
          scope: {:request, request_id}
        )
    end
  end

  defp perform_request_action(:retry_delivery, request_id) do
    request = Batching.get_request_by_id!(request_id, load: [:batch])

    with {:ok, _updated_request} <- Batching.retry_request_delivery(request) do
      {:ok, "Redelivery triggered"}
    else
      {:error, error} ->
        {:error, "Failed to retry delivery: #{Exception.message(error)}"}
    end
  end

  def pending_action?(pending_actions, action, request_id) do
    key = {:request_action, action, request_id}
    AsyncActions.pending?(pending_actions, key) or ActionActivity.active?(key)
  end

  def can_redeliver_request?(request, batch) do
    request.state != :delivering and not is_nil(request.response_payload) and
      not is_nil(batch) and batch.state != :delivering
  end

  defp parse_batch_id(nil), do: nil
  defp parse_batch_id(""), do: nil

  defp parse_batch_id(batch_id) when is_binary(batch_id) do
    case Integer.parse(batch_id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_batch_id(_), do: nil

  defp parse_state_filter(nil), do: nil
  defp parse_state_filter(""), do: nil

  defp parse_state_filter(state) when is_binary(state) do
    valid_states =
      Enum.map(state_filter_options(), fn {_label, value} -> Atom.to_string(value) end)

    if state in valid_states do
      String.to_existing_atom(state)
    else
      nil
    end
  end

  defp parse_state_filter(state) when is_atom(state) do
    valid_states = Enum.map(state_filter_options(), &elem(&1, 1))

    if state in valid_states do
      state
    else
      nil
    end
  end

  defp parse_state_filter(_), do: nil

  defp state_filter_param(nil), do: nil
  defp state_filter_param(state) when is_atom(state), do: Atom.to_string(state)

  defp sort_options do
    [
      {"Newest first", "-created_at"},
      {"Oldest first", "created_at"},
      {"Status", "status"},
      {"Model", "model"},
      {"Endpoint", "url"},
      {"Filter by Batch", "batch_filter"}
    ]
  end

  defp state_filter_options do
    [
      {"Pending", :pending},
      {"OpenAI processing", :openai_processing},
      {"OpenAI processed", :openai_processed},
      {"Delivering", :delivering},
      {"Delivered", :delivered},
      {"Failed (OpenAI)", :failed},
      {"Delivery failed", :delivery_failed},
      {"Expired", :expired},
      {"Cancelled", :cancelled}
    ]
  end

  defp validate_sort_by(key) when is_binary(key) do
    valid_keys = Enum.map(sort_options(), &elem(&1, 1))

    if key in valid_keys do
      key
    else
      "-created_at"
    end
  end

  defp validate_sort_by(_), do: "-created_at"

  defp is_batch_filter?(sort_by), do: sort_by == "batch_filter"

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
    assigns =
      assigns
      |> assign(:options, sort_options())
      |> assign(:is_batch_filter, is_batch_filter?(assigns.selected))
      |> assign(:batch_id_value, assigns[:batch_id] || "")

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
      <div :if={@is_batch_filter} class="flex items-center gap-2">
        <label for="batch_filter_input" class="text-sm text-base-content/70 whitespace-nowrap">
          Batch ID:
        </label>
        <input
          type="number"
          id="batch_filter_input"
          name="batch_id"
          value={@batch_id_value}
          placeholder="Enter batch ID"
          phx-debounce="300"
          phx-change="change-batch-filter"
          class="input input-bordered w-32 text-sm bg-base-200 border-base-300"
        />
      </div>
    </form>
    """
  end

  defp state_filter_changer(assigns) do
    options =
      [{"All states", ""}] ++
        Enum.map(state_filter_options(), fn {label, value} -> {label, Atom.to_string(value)} end)

    selected = state_filter_param(assigns[:state_filter]) || ""

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:selected, selected)

    ~H"""
    <form phx-change="change-state-filter" class="flex items-center gap-2">
      <label for="state_filter" class="text-sm text-base-content/70 whitespace-nowrap">
        State:
      </label>
      <select
        id="state_filter"
        name="state"
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
        placeholder="Search for custom ID"
        class="input pl-10 w-64 text-sm bg-base-200 border-base-300"
      />
    </form>
    """
  end

  defp clear_pending_refresh(socket) do
    socket
    |> assign(:pending_refresh_count, 0)
    |> assign(:pending_refresh_reasons, MapSet.new())
  end

  defp mark_pending_clear_on_next_params(socket) do
    assign(socket, :clear_pending_on_next_params?, true)
  end

  defp maybe_clear_pending_refresh(socket) do
    if socket.assigns.clear_pending_on_next_params? do
      socket
      |> clear_pending_refresh()
      |> assign(:clear_pending_on_next_params?, false)
    else
      socket
    end
  end

  defp buffer_pending_refresh(socket, reason) do
    socket
    |> update(:pending_refresh_count, &(&1 + 1))
    |> update(:pending_refresh_reasons, &MapSet.put(&1, reason))
    |> assign(:last_event_at_ms, System.monotonic_time(:millisecond))
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
