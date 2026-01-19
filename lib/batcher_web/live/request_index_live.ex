defmodule BatcherWeb.RequestIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
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

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query_text = Map.get(params, "q", "")
    sort_by = Map.get(params, "sort_by") |> validate_sort_by()

    page =
      Batching.search_requests!(query_text,
        page: AshPhoenix.LiveView.params_to_page_opts(params, default_limit: 25),
        query: [sort_input: sort_by]
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
      |> assign(:page, page)

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

    {:noreply, push_patch(socket, to: ~p"/requests?#{params}")}
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

    {:noreply, push_patch(socket, to: ~p"/requests?#{params}")}
  end

  @impl true
  def handle_info(%{topic: "requests:created", payload: %{data: _request}}, socket) do
    # Reload requests to include the new one (respects current filters/sort)
    {:noreply, reload_page(socket)}
  end

  @impl true
  def handle_info(
        %{topic: "requests:state_changed:" <> _request_id, payload: %{data: _request}},
        socket
      ) do
    # Reload the page to reflect state changes
    {:noreply, reload_page(socket)}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp reload_page(socket) do
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"

    page =
      Batching.search_requests!(query_text,
        page: [offset: socket.assigns.page.offset, limit: socket.assigns.page.limit],
        query: [sort_input: sort_by]
      )

    assign(socket, :page, page)
  end

  defp sort_options do
    [
      {"Newest first", "-created_at"},
      {"Oldest first", "created_at"},
      {"Recently updated", "-updated_at"},
      {"Least recently updated", "updated_at"},
      {"State (A-Z)", "state"},
      {"State (Z-A)", "-state"},
      {"Custom ID (A-Z)", "custom_id"},
      {"Custom ID (Z-A)", "-custom_id"},
      {"Model (A-Z)", "model"},
      {"Model (Z-A)", "-model"},
      {"Batch ID (High)", "-batch_id"},
      {"Batch ID (Low)", "batch_id"}
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

  defp remove_empty(params) do
    Enum.filter(params, fn {_key, val} ->
      case val do
        "" -> false
        nil -> false
        _ -> true
      end
    end)
  end

  defp query_string(page, query_text, sort_by, which) do
    case AshPhoenix.LiveView.page_link_params(page, which) do
      :invalid -> []
      list -> list
    end
    |> Keyword.put(:q, query_text)
    |> Keyword.put(:sort_by, sort_by)
    |> remove_empty()
  end

  defp pagination_links(assigns) do
    ~H"""
    <div class="flex items-center justify-center gap-4 py-3 px-4 bg-base-200/50 border-t border-base-300/50 shrink-0">
      <div class="join">
        <.link
          patch={~p"/requests?#{query_string(@page, @query_text, @sort_by, "prev")}"}
          class={["join-item btn btn-sm", !AshPhoenix.LiveView.prev_page?(@page) && "btn-disabled"]}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Previous
        </.link>
        <.link
          patch={~p"/requests?#{query_string(@page, @query_text, @sort_by, "next")}"}
          class={["join-item btn btn-sm", !AshPhoenix.LiveView.next_page?(@page) && "btn-disabled"]}
        >
          Next <.icon name="hero-chevron-right" class="w-4 h-4" />
        </.link>
      </div>
    </div>
    """
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
        placeholder="Search custom ID or model..."
        class="input pl-10 w-64 text-sm bg-base-200 border-base-300"
      />
    </form>
    """
  end
end
