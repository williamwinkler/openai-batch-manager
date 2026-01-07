defmodule Batcher.Batching.RequestDeliveryAttemptTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching.RequestDeliveryAttempt

  import Batcher.Generator

  describe "creating delivery attempt records" do
    test "creates successful delivery attempt" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      # type is not accepted by create action, so we need to set it after creation
      # or use force_change_attribute. For now, let's test what's actually accepted.
      changeset =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true,
          type: :webhook
        })

      {:ok, attempt} = Ash.create(changeset)

      assert attempt.request_id == request.id
      assert attempt.type == :webhook
      assert attempt.success == true
      assert attempt.error_msg == nil
      assert attempt.attempted_at
    end

    test "creates failed delivery attempt with error message" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      changeset =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: false,
          error_msg: "HTTP 500 Internal Server Error",
          type: :webhook
        })

      {:ok, attempt} = Ash.create(changeset)

      assert attempt.request_id == request.id
      assert attempt.type == :webhook
      assert attempt.success == false
      assert attempt.error_msg == "HTTP 500 Internal Server Error"
      assert attempt.attempted_at
    end

    test "creates RabbitMQ delivery attempt" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      changeset =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true,
          type: :rabbitmq
        })

      {:ok, attempt} = Ash.create(changeset)

      assert attempt.type == :rabbitmq
      assert attempt.success == true
    end
  end

  describe "loading attempts for a request" do
    test "loads delivery attempts relationship" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      # Create multiple attempts
      changeset1 =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: false,
          error_msg: "First attempt failed",
          type: :webhook
        })

      {:ok, _attempt1} = Ash.create(changeset1)

      changeset2 =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true,
          type: :webhook
        })

      {:ok, _attempt2} = Ash.create(changeset2)

      # Load request with attempts
      request = Ash.load!(request, [:delivery_attempts])

      assert length(request.delivery_attempts) == 2

      failed_attempt = Enum.find(request.delivery_attempts, &(!&1.success))
      assert failed_attempt.error_msg == "First attempt failed"

      successful_attempt = Enum.find(request.delivery_attempts, & &1.success)
      assert successful_attempt.success == true
    end

    test "attempts are ordered by attempted_at" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      # Create attempts with slight delay
      changeset1 =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: false,
          type: :webhook
        })

      {:ok, _attempt1} = Ash.create(changeset1)

      # Small delay to ensure different timestamps
      Process.sleep(10)

      changeset2 =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true,
          type: :webhook
        })

      {:ok, _attempt2} = Ash.create(changeset2)

      request = Ash.load!(request, [:delivery_attempts])

      attempts = request.delivery_attempts
      assert length(attempts) == 2

      # Verify chronological order (first attempt should be earlier)
      first_time = Enum.at(attempts, 0).attempted_at
      second_time = Enum.at(attempts, 1).attempted_at
      assert DateTime.compare(first_time, second_time) != :gt
    end
  end

  describe "success/failure tracking" do
    test "tracks multiple failed attempts" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      for i <- 1..3 do
        changeset =
          RequestDeliveryAttempt
          |> Ash.Changeset.for_create(:create, %{
            request_id: request.id,
            success: false,
            error_msg: "Attempt #{i} failed",
            type: :webhook
          })

        {:ok, _attempt} = Ash.create(changeset)
      end

      request = Ash.load!(request, [:delivery_attempts])

      failed_attempts = Enum.filter(request.delivery_attempts, &(!&1.success))
      assert length(failed_attempts) == 3
    end

    test "tracks successful attempt after failures" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      # Create failed attempts
      for _i <- 1..2 do
        changeset =
          RequestDeliveryAttempt
          |> Ash.Changeset.for_create(:create, %{
            request_id: request.id,
            success: false,
            error_msg: "Failed",
            type: :webhook
          })

        {:ok, _attempt} = Ash.create(changeset)
      end

      # Create successful attempt
      changeset =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true,
          type: :webhook
        })

      {:ok, _success_attempt} = Ash.create(changeset)

      request = Ash.load!(request, [:delivery_attempts])

      assert length(request.delivery_attempts) == 3

      successful_attempts = Enum.filter(request.delivery_attempts, & &1.success)
      assert length(successful_attempts) == 1
    end
  end

  describe "relationship loading" do
    test "belongs_to request relationship works" do
      batch = generate(batch())
      request = generate(seeded_request(batch_id: batch.id, custom_id: "test_req"))

      # type is not accepted by create action, so we need to set it after creation
      # or use force_change_attribute. For now, let's test what's actually accepted.
      changeset =
        RequestDeliveryAttempt
        |> Ash.Changeset.for_create(:create, %{
          request_id: request.id,
          success: true,
          type: :webhook
        })

      {:ok, attempt} = Ash.create(changeset)

      # Load attempt with request
      attempt = Ash.load!(attempt, [:request])

      assert attempt.request.id == request.id
      assert attempt.request.custom_id == request.custom_id
    end
  end
end
