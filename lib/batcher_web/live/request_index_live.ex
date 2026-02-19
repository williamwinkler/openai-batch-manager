defmodule BatcherWeb.RequestIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias BatcherWeb.Live.Utils.AsyncPagination
  alias Batcher.Utils.Format

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to request creation events
    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("requests:created")
    end

    socket =
      socket
      |> assign(:page_title, "Requests")
      |> AsyncPagination.init()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query_text = Map.get(params, "q", "")
    sort_by_param = Map.get(params, "sort_by")
    batch_id = parse_batch_id(Map.get(params, "batch_id"))

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

    page_opts =
      AshPhoenix.LiveView.params_to_page_opts(params, default_limit: 25)
      |> Keyword.put(:count, false)

    page =
      Batching.search_requests!(
        query_text,
        %{sort_input: sort_input, batch_id: batch_id},
        page: page_opts
      )

    # Subscribe to state changes for requests on current page
    if connected?(socket) do
      Enum.each(page.results, fn request ->
        BatcherWeb.Endpoint.subscribe("requests:state_changed:#{request.id}")
      end)
    end

    socket =
      socket
      |> assign(:query_text, query_text)
      |> assign(:sort_by, sort_by)
      |> assign(:batch_id, batch_id)
      |> assign(:page, page)
      |> schedule_count(query_text, sort_input, batch_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    params =
      [
        q: query,
        sort_by: socket.assigns.sort_by,
        batch_id: socket.assigns.batch_id
      ]
      |> remove_empty()

    {:noreply, push_patch(socket, to: ~p"/requests?#{params}")}
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
        batch_id: batch_id
      ]
      |> remove_empty()

    {:noreply, push_patch(socket, to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("change-batch-filter", %{"batch_id" => batch_id_str}, socket) do
    batch_id = parse_batch_id(batch_id_str)

    params =
      [
        q: socket.assigns.query_text,
        sort_by: socket.assigns.sort_by,
        batch_id: batch_id
      ]
      |> remove_empty()

    {:noreply, push_patch(socket, to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_event("clear_batch_filter", _params, socket) do
    params =
      [
        q: socket.assigns.query_text,
        sort_by: socket.assigns.sort_by
      ]
      |> remove_empty()

    {:noreply, push_patch(socket, to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_info(%{topic: "requests:created", payload: %{data: _request}}, socket) do
    # Reload requests to include the new one (respects current filters/sort)
    {:noreply, reload_page(socket, refresh_count?: false)}
  end

  @impl true
  def handle_info(
        %{topic: "requests:state_changed:" <> _request_id, payload: %{data: _request}},
        socket
      ) do
    # Reload the page to reflect state changes
    {:noreply, reload_page(socket, refresh_count?: false)}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_async({:page_count, count_request_key}, result, socket) do
    {:noreply, AsyncPagination.handle_count_async(socket, count_request_key, result)}
  end

  defp reload_page(socket, opts) do
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"
    batch_id = socket.assigns[:batch_id]

    # If batch_filter is selected but no batch_id, use default sort
    sort_input =
      if sort_by == "batch_filter" and is_nil(batch_id), do: "-created_at", else: sort_by

    page =
      Batching.search_requests!(
        query_text,
        %{sort_input: sort_input, batch_id: batch_id},
        page: [
          offset: socket.assigns.page.offset,
          limit: socket.assigns.page.limit,
          count: false
        ]
      )

    socket = assign(socket, :page, page)

    if Keyword.get(opts, :refresh_count?, true) do
      schedule_count(socket, query_text, sort_input, batch_id)
    else
      socket
    end
  end

  defp schedule_count(socket, query_text, sort_input, batch_id) do
    count_request_key = {:requests_count, query_text, sort_input, batch_id}

    AsyncPagination.schedule_count(socket, count_request_key, fn ->
      count_requests(query_text, batch_id)
    end)
  end

  defp count_requests(query_text, batch_id) do
    maybe_test_count_delay(query_text)

    if maybe_test_count_error?(query_text) do
      {:error, :forced_count_error}
    else
      case Batching.count_requests_for_search(
             query_text,
             %{batch_id: batch_id},
             page: [limit: 1, count: true]
           ) do
        {:ok, page} -> {:ok, page.count || 0}
        {:error, error} -> {:error, error}
      end
    end
  end

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

  defp parse_batch_id(nil), do: nil
  defp parse_batch_id(""), do: nil

  defp parse_batch_id(batch_id) when is_binary(batch_id) do
    case Integer.parse(batch_id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_batch_id(_), do: nil

  defp sort_options do
    [
      {"Newest first", "-created_at"},
      {"Oldest first", "created_at"},
      {"Filter by Batch", "batch_filter"}
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
        placeholder="Search custom ID or model..."
        class="input pl-10 w-64 text-sm bg-base-200 border-base-300"
      />
    </form>
    """
  end

  defp batch_filter_badge(assigns) do
    ~H"""
    <div class="badge badge-primary gap-1.5 py-3">
      <span>Batch #{@batch_id}</span>
      <button
        type="button"
        phx-click="clear_batch_filter"
        class="hover:bg-primary-focus rounded-full p-0.5"
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end
end
