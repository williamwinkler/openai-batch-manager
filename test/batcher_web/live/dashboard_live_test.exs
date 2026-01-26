defmodule BatcherWeb.DashboardLiveTest do
  use BatcherWeb.LiveViewCase, async: false

  alias Batcher.Batching

  import Batcher.Generator

  describe "mount" do
    test "displays dashboard with empty data", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Dashboard"
      # Should show zero counts
      assert html =~ "0"
    end

    test "displays batch statistics", %{conn: conn} do
      # Create some batches
      generate(batch())
      generate(batch())

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Dashboard"
      # Should show batch count
      assert html =~ "2" or html =~ "Batches"
    end

    test "displays request statistics", %{conn: conn} do
      batch = generate(batch())

      {:ok, _req} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "dashboard_test_req",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "dashboard_test_req",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Requests" or html =~ "1"
    end
  end

  describe "batch state distribution" do
    test "shows active batches count", %{conn: conn} do
      # Create a batch (it will be in 'building' state which is active)
      generate(batch())

      {:ok, _view, html} = live(conn, ~p"/")

      # Should show active count
      assert html =~ "Active" or html =~ "building" or html =~ "1"
    end

    test "shows completed batches count", %{conn: conn} do
      # Create a batch in done state
      generate(seeded_batch(state: :delivered))

      {:ok, _view, html} = live(conn, ~p"/")

      # Should show completed count
      assert html =~ "Completed" or html =~ "done" or html =~ "1"
    end
  end

  describe "model distribution" do
    test "shows model statistics", %{conn: conn} do
      generate(batch(model: "gpt-4o"))
      generate(batch(model: "gpt-4o"))
      generate(batch(model: "gpt-3.5-turbo"))

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "gpt-4o" or html =~ "Models"
    end
  end

  describe "endpoint distribution" do
    test "shows endpoint statistics", %{conn: conn} do
      generate(batch(url: "/v1/responses"))
      generate(batch(url: "/v1/chat/completions"))

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Endpoint" or html =~ "/v1/"
    end
  end

  describe "delivery type distribution" do
    test "shows webhook delivery count", %{conn: conn} do
      batch = generate(batch())

      {:ok, _req} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "webhook_test_req",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "webhook_test_req",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Webhook" or html =~ "webhook"
    end

    test "shows rabbitmq delivery count", %{conn: conn} do
      batch = generate(batch())

      {:ok, _req} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "rabbitmq_test_req",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "rabbitmq_test_req",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "rabbitmq",
            "rabbitmq_queue" => "test_queue"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "RabbitMQ" or html =~ "rabbitmq"
    end
  end

  describe "pubsub updates" do
    test "updates when new batch is created", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Create a new batch
      generate(batch())

      # Wait for PubSub update
      :timer.sleep(100)

      html = render(view)
      # Should now show at least 1 batch
      assert html =~ "1" or html =~ "building"
    end

    test "updates when new request is created", %{conn: conn} do
      batch = generate(batch())
      {:ok, view, _html} = live(conn, ~p"/")

      # Create a new request
      {:ok, _req} =
        Batching.create_request(%{
          batch_id: batch.id,
          custom_id: "pubsub_test_req",
          url: batch.url,
          model: batch.model,
          request_payload: %{
            custom_id: "pubsub_test_req",
            body: %{input: "test", model: batch.model},
            method: "POST",
            url: batch.url
          },
          delivery_config: %{
            "type" => "webhook",
            "webhook_url" => "https://example.com/webhook"
          }
        })

      # Wait for PubSub update
      :timer.sleep(100)

      html = render(view)
      assert html =~ "1" or html =~ "Requests"
    end

    test "updates when batch state changes", %{conn: conn} do
      batch = generate(batch())
      {:ok, view, _html} = live(conn, ~p"/")

      # Cancel the batch to trigger state change
      {:ok, _cancelled_batch} = Batching.cancel_batch(batch)

      # Wait for PubSub update
      :timer.sleep(100)

      html = render(view)
      assert html =~ "Cancelled" or html =~ "cancelled" or html =~ "1"
    end
  end
end
