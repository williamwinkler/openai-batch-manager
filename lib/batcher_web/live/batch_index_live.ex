defmodule BatcherWeb.BatchIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to batch creation events
    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:created")
    end

    socket =
      socket
      |> assign(:page_title, "Batch Manager")
      |> assign(:query_text, "")
      |> assign(:sort_by, "-created_at")
      |> assign(:current_scope, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    query_text = Map.get(params, "q", socket.assigns[:query_text] || "")
    sort_by = Map.get(params, "sort_by") |> validate_sort_by()

    socket =
      socket
      |> assign(:current_path, "/")
      |> assign(:query_text, query_text)
      |> assign(:sort_by, sort_by)

    {:noreply, load_batches(socket, page, query_text, sort_by)}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page = String.to_integer(page)
    params = build_params(socket, page: page)
    {:noreply, push_patch(socket, to: build_url(params))}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    params = build_params(socket, q: query, page: 1)
    {:noreply, push_patch(socket, to: build_url(params))}
  end

  @impl true
  def handle_event("change-sort", %{"sort_by" => sort_by}, socket) do
    sort_by = validate_sort_by(sort_by)
    params = build_params(socket, sort_by: sort_by, page: 1)
    {:noreply, push_patch(socket, to: build_url(params))}
  end

  @impl true
  def handle_event("upload_batch", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Batching.get_batch_by_id(id) do
      {:ok, batch} ->
        if batch.state == :building do
          case Batcher.BatchBuilder.upload_batch(batch.url, batch.model) do
            :ok ->
              {:noreply, put_flash(socket, :info, "Batch upload initiated successfully")}

            {:error, reason} ->
              error_msg =
                case reason do
                  :noproc -> "BatchBuilder not found. The batch may have already been uploaded."
                  other -> "Failed to upload batch: #{inspect(other)}"
                end

              {:noreply, put_flash(socket, :error, error_msg)}
          end
        else
          {:noreply, put_flash(socket, :error, "Batch is not in building state")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Batch not found")}
    end
  end

  @impl true
  def handle_event("cancel_batch", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Batching.get_batch_by_id(id) do
      {:ok, batch} ->
        case Batching.cancel_batch(batch) do
          {:ok, _} ->
            {:noreply, put_flash(socket, :info, "Batch cancelled successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to cancel batch")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Batch not found")}
    end
  end

  @impl true
  def handle_event("delete_batch", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Batching.get_batch_by_id(id) do
      {:ok, batch} ->
        case Batching.destroy_batch(batch) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Batch deleted successfully")
             |> stream_delete(:batches, batch)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete batch")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Batch not found")}
    end
  end

  @impl true
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: batch}},
        socket
      ) do
    {:noreply, stream(socket, :batches, [batch], reset: false)}
  end

  @impl true
  def handle_info(%{topic: "batches:created", payload: %{data: _batch}}, socket) do
    # Reload batches to include the new one (respects current filters/sort)
    page = socket.assigns[:page] || 1
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"
    {:noreply, load_batches(socket, page, query_text, sort_by)}
  end

  @impl true
  def handle_info(%{topic: "batches:created:" <> _batch_id, payload: %{data: _batch}}, socket) do
    # Also handle individual batch creation events
    page = socket.assigns[:page] || 1
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"
    {:noreply, load_batches(socket, page, query_text, sort_by)}
  end

  @impl true
  def handle_info(%{topic: "batches:destroyed:" <> _batch_id, payload: %{data: batch}}, socket) do
    {:noreply, stream_delete(socket, :batches, batch)}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp load_batches(socket, page, query_text, sort_by) do
    skip = (page - 1) * @per_page

    query =
      Batching.Batch
      |> Ash.Query.for_read(:list_paginated,
        skip: skip,
        limit: @per_page,
        query: query_text,
        sort_by: sort_by
      )

    case Ash.read!(query, page: [offset: skip, limit: @per_page, count: true]) do
      %Ash.Page.Offset{results: batches, count: total_count, more?: _more} ->
        # Load request_count for each batch
        batches_with_count =
          Enum.map(batches, fn batch ->
            Ash.load!(batch, :request_count)
          end)

        # Subscribe to PubSub for batches on current page
        if connected?(socket) do
          Enum.each(batches_with_count, fn batch ->
            BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch.id}")
            BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch.id}")
          end)
        end

        socket
        |> stream(:batches, batches_with_count, reset: true)
        |> assign(:page, page)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, total_count || 0)

      _ ->
        socket
        |> stream(:batches, [], reset: true)
        |> assign(:page, page)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, 0)
    end
  end

  defp sort_options do
    [
      {"Newest first", "created_at"},
      {"Oldest first", "created_at"},
      {"State (A-Z)", "state"},
      {"State (Z-A)", "-state"},
      {"Request count (High)", "-request_count"},
      {"Request count (Low)", "request_count"},
      {"Model (A-Z)", "model"},
      {"Model (Z-A)", "-model"},
      {"Endpoint (A-Z)", "url"},
      {"Endpoint (Z-A)", "-url"}
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

  defp build_params(socket, opts) do
    query_text = Keyword.get(opts, :q, socket.assigns.query_text)
    sort_by = Keyword.get(opts, :sort_by, socket.assigns.sort_by)
    page = Keyword.get(opts, :page, socket.assigns.page)

    params = []
    params = if query_text != "", do: Keyword.put(params, :q, query_text), else: params
    params = if sort_by != "-created_at", do: Keyword.put(params, :sort_by, sort_by), else: params
    params = if page != 1, do: Keyword.put(params, :page, page), else: params

    params
  end

  defp build_url([]), do: ~p"/"

  defp build_url(params) do
    query_string = URI.encode_query(params)
    ~p"/?#{query_string}"
  end

  defp sort_changer(assigns) do
    assigns = assign(assigns, :options, sort_options())

    ~H"""
    <form phx-change="change-sort" class="flex items-center gap-2">
      <label for="sort_by" class="text-sm text-base-content/70">Sort by:</label>
      <.input
        type="select"
        id="sort_by"
        name="sort_by"
        options={@options}
        value={@selected}
        class="!w-auto !min-w-[180px] text-sm"
      />
    </form>
    """
  end

  defp search_box(assigns) do
    ~H"""
    <form class="relative" phx-change="search" phx-submit="search">
      <.icon
        name="hero-magnifying-glass"
        class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/50"
      />
      <label for="search-query" class="hidden">Search</label>
      <.input
        type="text"
        name="query"
        id="search-query"
        value={@query}
        placeholder="Search model or endpoint..."
        class="!pl-10 !w-64 text-sm"
      />
    </form>
    """
  end
end
