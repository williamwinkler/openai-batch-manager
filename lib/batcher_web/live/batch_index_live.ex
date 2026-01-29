defmodule BatcherWeb.BatchIndexLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Utils.Format

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to batch creation events
    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:created")
      BatcherWeb.Endpoint.subscribe("requests:created")
    end

    socket =
      socket
      |> assign(:page_title, "Batches")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query_text = Map.get(params, "q", "")
    sort_by = Map.get(params, "sort_by") |> validate_sort_by()

    page_opts =
      AshPhoenix.LiveView.params_to_page_opts(params, default_limit: 20)
      |> Keyword.put(:count, true)

    page =
      Batching.search_batches!(query_text,
        page: page_opts,
        query: [sort_input: sort_by]
      )

    # Subscribe to state changes for batches on current page
    if connected?(socket) do
      Enum.each(page.results, fn batch ->
        BatcherWeb.Endpoint.subscribe("batches:state_changed:#{batch.id}")
        BatcherWeb.Endpoint.subscribe("batches:destroyed:#{batch.id}")
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
                  :noproc ->
                    "BatchBuilder not found. The batch may have already been uploaded."

                  :no_building_batch ->
                    "No batch in building state found for this model/endpoint."

                  other ->
                    "Failed to upload batch: #{inspect(other)}"
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
            {:noreply,
             socket
             |> put_flash(:info, "Batch cancelled successfully")
             |> reload_page()}

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
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Batch deleted successfully")
             |> reload_page()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete batch")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Batch not found")}
    end
  end

  @impl true
  def handle_event("redeliver_batch", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Batching.redeliver_batch(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Redelivery initiated for failed requests")
         |> reload_page()}

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
  def handle_info(
        %{topic: "batches:state_changed:" <> _batch_id, payload: %{data: _batch}},
        socket
      ) do
    # Reload the page to reflect state changes
    {:noreply, reload_page(socket)}
  end

  @impl true
  def handle_info(%{topic: "batches:created", payload: %{data: _batch}}, socket) do
    # Reload batches to include the new one (respects current filters/sort)
    {:noreply, reload_page(socket)}
  end

  @impl true
  def handle_info(%{topic: "batches:created:" <> _batch_id, payload: %{data: _batch}}, socket) do
    # Also handle individual batch creation events
    {:noreply, reload_page(socket)}
  end

  @impl true
  def handle_info(%{topic: "batches:destroyed:" <> _batch_id, payload: %{data: _batch}}, socket) do
    {:noreply, reload_page(socket)}
  end

  @impl true
  def handle_info(
        %{topic: "requests:created", payload: %{data: request}},
        socket
      ) do
    # Check if the request belongs to any batch on the current page
    batch_ids_on_page = Enum.map(socket.assigns.page.results, & &1.id)

    if request.batch_id in batch_ids_on_page do
      # Reload the page to update request counts
      {:noreply, reload_page(socket)}
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
      {:noreply, reload_page(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp reload_page(socket) do
    query_text = socket.assigns[:query_text] || ""
    sort_by = socket.assigns[:sort_by] || "-created_at"

    page =
      Batching.search_batches!(query_text,
        page: [offset: socket.assigns.page.offset, limit: socket.assigns.page.limit, count: true],
        query: [sort_input: sort_by]
      )

    assign(socket, :page, page)
  end

  defp sort_options do
    [
      {"Newest first", "-created_at"},
      {"Oldest first", "created_at"},
      {"State (A-Z)", "state"},
      {"State (Z-A)", "-state"},
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
