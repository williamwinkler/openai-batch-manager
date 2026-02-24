# priv/scripts/rabbitmq_requests.exs
# Script to send test messages to RabbitMQ input queue
#
# Usage: mix run priv/scripts/rabbitmq_requests.exs
#
# Requirements:
# - RabbitMQ running at amqp://guest:guest@localhost:5672
# - Queue "test-input-queue" will be created if it doesn't exist

# RabbitMQ connection settings
rabbitmq_url = "amqp://guest:guest@localhost:5672"
input_queue = "test-input-queue"

# Helper function to generate random model
random_model = fn ->
  Enum.random([
    "gpt-4o-mini",
    "gpt-4o",
    "gpt-4.1-mini",
    "gpt-4.1",
    "gpt-5",
    "gpt-5-mini",
    "gpt-5.1",
    "gpt-5.2",
    "o3-mini",
    "o3",
    "o4-mini",
    "o4"
  ])
end

# Helper function to generate a request message
build_request = fn custom_id, model, delivery_config ->
  %{
    "custom_id" => custom_id,
    "url" => "/v1/responses",
    "method" => "POST",
    "body" => %{
      "input" =>
        "Analyze the following product review and extract key information: 'I bought this laptop last month and it's been amazing! The battery lasts 10 hours, the screen is crystal clear, and it runs all my apps smoothly. The only downside is it's a bit heavy at 2.5kg. Overall rating: 4.5/5 stars.'",
      "model" => model
    },
    "delivery_config" => delivery_config
  }
end

# Connect to RabbitMQ
IO.puts("Connecting to RabbitMQ at #{rabbitmq_url}...")

case AMQP.Connection.open(rabbitmq_url) do
  {:ok, conn} ->
    IO.puts("✓ Connected to RabbitMQ")

    case AMQP.Channel.open(conn) do
      {:ok, chan} ->
        IO.puts("✓ Channel opened")

        # Ensure the input queue exists
        case AMQP.Queue.declare(chan, input_queue, durable: true) do
          {:ok, _} ->
            IO.puts("✓ Queue '#{input_queue}' declared/verified")

            # Send 25 messages with delivery_config set to rabbitmq with queue "test-output-queue"
            IO.puts("\nSending 25 messages with delivery_config to 'test-output-queue'...")

            for i <- 1..25 do
              custom_id = Ecto.UUID.generate()
              model = "gpt-4o-mini"

              delivery_config = %{
                "type" => "rabbitmq",
                "rabbitmq_queue" => "test-output-queue"
              }

              message = build_request.(custom_id, model, delivery_config)
              json_message = JSON.encode!(message)

              case AMQP.Basic.publish(chan, "", input_queue, json_message, persistent: true) do
                :ok ->
                  IO.puts("  [#{i}/25] Published message with custom_id=#{custom_id}")

                error ->
                  IO.puts("  [#{i}/25] Failed to publish: #{inspect(error)}")
              end
            end

            # Send 5 messages with random queue names (that don't exist)
            IO.puts("\nSending 5 messages with random queue names (non-existent queues)...")

            for i <- 1..5 do
              custom_id = Ecto.UUID.generate()
              model = "gpt-4o-mini"
              random_queue = "non-existent-queue-#{Ecto.UUID.generate()}"

              delivery_config = %{
                "type" => "rabbitmq",
                "rabbitmq_queue" => random_queue
              }

              message = build_request.(custom_id, model, delivery_config)
              json_message = JSON.encode!(message)

              case AMQP.Basic.publish(chan, "", input_queue, json_message, persistent: true) do
                :ok ->
                  IO.puts("  [#{i}/5] Published message with custom_id=#{custom_id}, queue=#{random_queue}")

                error ->
                  IO.puts("  [#{i}/5] Failed to publish: #{inspect(error)}")
              end
            end

            IO.puts("\n✓ All messages published successfully!")
            IO.puts("  - 25 messages with delivery to 'test-output-queue'")
            IO.puts("  - 5 messages with delivery to non-existent queues")

            # Clean up
            AMQP.Channel.close(chan)
            AMQP.Connection.close(conn)
            IO.puts("\n✓ Connection closed")

          {:error, reason} ->
            IO.puts("✗ Failed to declare queue: #{inspect(reason)}")
            AMQP.Channel.close(chan)
            AMQP.Connection.close(conn)
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts("✗ Failed to open channel: #{inspect(reason)}")
        AMQP.Connection.close(conn)
        System.halt(1)
    end

  {:error, reason} ->
    IO.puts("✗ Failed to connect to RabbitMQ: #{inspect(reason)}")
    IO.puts("  Make sure RabbitMQ is running at #{rabbitmq_url}")
    System.halt(1)
end
