defmodule BatcherWeb.DashboardLive do
  use BatcherWeb, :live_view

  alias Batcher.Batching
  alias Batcher.Batching.Types.BatchStatus

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      BatcherWeb.Endpoint.subscribe("batches:created")
      BatcherWeb.Endpoint.subscribe("requests:created")
      BatcherWeb.Endpoint.subscribe("batches:state_changed")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> reload_statistics()

    {:ok, socket}
  end

  @impl true
  def handle_info(%{topic: "batches:" <> _}, socket) do
    {:noreply, reload_statistics(socket)}
  end

  @impl true
  def handle_info(%{topic: "requests:" <> _}, socket) do
    {:noreply, reload_statistics(socket)}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  # SVG Pie Chart Component
  attr :segments, :list, required: true
  attr :size, :integer, default: 160

  defp pie_chart(assigns) do
    ~H"""
    <svg width={@size} height={@size} viewBox="-1 -1 2 2" style="transform: rotate(-90deg)">
      <%= for segment <- @segments do %>
        <circle
          cx="0"
          cy="0"
          r="0.85"
          fill="transparent"
          stroke={segment.color}
          stroke-width="0.3"
          stroke-dasharray={"#{segment.dash} #{segment.gap}"}
          stroke-dashoffset={segment.offset}
        />
      <% end %>
      <!-- Center hole for donut effect -->
      <circle cx="0" cy="0" r="0.55" class="fill-base-100" />
    </svg>
    """
  end

  defp reload_statistics(socket) do
    batch_stats = get_batch_stats()
    request_stats = get_request_stats()
    model_stats = get_model_stats()
    endpoint_stats = get_endpoint_stats()
    delivery_stats = get_delivery_stats()

    total_batches = Enum.reduce(batch_stats, 0, fn {_, count}, acc -> acc + count end)
    total_requests = request_stats.total

    active_states = [
      :building,
      :uploading,
      :uploaded,
      :openai_processing,
      :openai_completed,
      :downloading,
      :downloaded,
      :ready_to_deliver,
      :delivering
    ]

    active_batches =
      Enum.reduce(active_states, 0, fn state, acc -> acc + Map.get(batch_stats, state, 0) end)

    completed_batches = Map.get(batch_stats, :delivered, 0)

    # Prepare chart data
    batch_chart_data = prepare_batch_chart_data(batch_stats, total_batches)
    delivery_chart_data = prepare_delivery_chart_data(delivery_stats)

    socket
    |> assign(:batch_stats, batch_stats)
    |> assign(:request_stats, request_stats)
    |> assign(:model_stats, model_stats)
    |> assign(:endpoint_stats, endpoint_stats)
    |> assign(:delivery_stats, delivery_stats)
    |> assign(:total_batches, total_batches)
    |> assign(:total_requests, total_requests)
    |> assign(:active_batches, active_batches)
    |> assign(:completed_batches, completed_batches)
    |> assign(:batch_chart_segments, batch_chart_data.segments)
    |> assign(:batch_chart_legend, batch_chart_data.legend)
    |> assign(:delivery_chart_segments, delivery_chart_data.segments)
  end

  defp prepare_batch_chart_data(batch_stats, total) when total > 0 do
    # Group states into categories for cleaner visualization
    categories = [
      {"In Progress", [:building, :uploading, :uploaded], "#38bdf8", "bg-info"},
      {"Processing", [:openai_processing, :openai_completed, :downloading, :downloaded],
       "#fbbf24", "bg-warning"},
      {"Delivering", [:ready_to_deliver, :delivering], "#a78bfa", "bg-accent"},
      {"Completed", [:delivered], "#4ade80", "bg-success"},
      {"Failed", [:failed, :expired], "#f87171", "bg-error"},
      {"Cancelled", [:cancelled], "#9ca3af", "bg-neutral"}
    ]

    category_counts =
      categories
      |> Enum.map(fn {label, states, color, bg_class} ->
        count = Enum.reduce(states, 0, fn state, acc -> acc + Map.get(batch_stats, state, 0) end)
        {label, count, color, bg_class}
      end)
      |> Enum.filter(fn {_, count, _, _} -> count > 0 end)

    circumference = 2 * :math.pi() * 0.85

    {segments, _} =
      Enum.reduce(category_counts, {[], 0.0}, fn {_label, count, color, _bg_class},
                                                 {segs, offset} ->
        percentage = count / total
        dash = percentage * circumference
        gap = circumference - dash

        segment = %{
          color: color,
          dash: Float.round(dash, 4),
          gap: Float.round(gap, 4),
          offset: Float.round(-offset, 4)
        }

        {segs ++ [segment], offset + dash}
      end)

    legend =
      Enum.map(category_counts, fn {label, count, _color, bg_class} ->
        {label, count, bg_class}
      end)

    %{segments: segments, legend: legend}
  end

  defp prepare_batch_chart_data(_batch_stats, _total) do
    %{segments: [], legend: []}
  end

  defp prepare_delivery_chart_data(%{webhook: webhook, rabbitmq: rabbitmq, total: total})
       when total > 0 do
    circumference = 2 * :math.pi() * 0.85

    webhook_pct = webhook / total
    rabbitmq_pct = rabbitmq / total

    webhook_dash = webhook_pct * circumference
    rabbitmq_dash = rabbitmq_pct * circumference

    segments = []

    segments =
      if webhook > 0 do
        segments ++
          [
            %{
              color: "#7c3aed",
              dash: Float.round(webhook_dash, 4),
              gap: Float.round(circumference - webhook_dash, 4),
              offset: 0.0
            }
          ]
      else
        segments
      end

    segments =
      if rabbitmq > 0 do
        segments ++
          [
            %{
              color: "#ec4899",
              dash: Float.round(rabbitmq_dash, 4),
              gap: Float.round(circumference - rabbitmq_dash, 4),
              offset: Float.round(-webhook_dash, 4)
            }
          ]
      else
        segments
      end

    %{segments: segments}
  end

  defp prepare_delivery_chart_data(_delivery_stats) do
    %{segments: []}
  end

  defp get_batch_stats do
    batches = Batching.Batch |> Ash.read!()

    BatchStatus.values()
    |> Enum.map(fn batch_state ->
      count = Enum.count(batches, fn b -> b.state == batch_state end)
      {batch_state, count}
    end)
    |> Map.new()
  end

  defp get_request_stats do
    total = Batching.Request |> Ash.count!()
    %{total: total}
  end

  defp get_model_stats do
    Batching.Batch
    |> Ash.read!()
    |> Enum.frequencies_by(& &1.model)
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(10)
  end

  defp get_endpoint_stats do
    Batching.Batch
    |> Ash.read!()
    |> Enum.frequencies_by(& &1.url)
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(10)
  end

  defp get_delivery_stats do
    requests = Batching.Request |> Ash.read!()
    total = length(requests)

    webhook_count =
      Enum.count(requests, fn r ->
        get_in(r.delivery_config, ["type"]) == "webhook"
      end)

    rabbitmq_count =
      Enum.count(requests, fn r ->
        get_in(r.delivery_config, ["type"]) == "rabbitmq"
      end)

    %{
      webhook: webhook_count,
      rabbitmq: rabbitmq_count,
      total: total
    }
  end

  defp percentage(count, total) when total > 0, do: Float.round(count / total * 100, 1)
  defp percentage(_, _), do: 0.0
end
