defmodule Batcher.Batching.Changes.SetPayloadTest do
  use Batcher.DataCase, async: false

  alias Batcher.Batching
  alias Batcher.Batching.Changes.SetPayload

  import Batcher.Generator

  describe "change/3" do
    test "encodes request payload as JSON string" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      payload_map = %{
        custom_id: custom_id,
        body: %{input: "test", model: model},
        method: "POST",
        url: url
      }

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: payload_map,
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      # Apply SetPayload change
      changeset = SetPayload.change(changeset, [], %{})

      assert changeset.valid?
      assert is_binary(Ash.Changeset.get_attribute(changeset, :request_payload))
      assert String.contains?(Ash.Changeset.get_attribute(changeset, :request_payload), custom_id)
      assert String.contains?(Ash.Changeset.get_attribute(changeset, :request_payload), model)
    end

    test "calculates payload size correctly" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      payload_map = %{
        custom_id: custom_id,
        body: %{input: "test", model: model},
        method: "POST",
        url: url
      }

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: payload_map,
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      payload_json = Ash.Changeset.get_attribute(changeset, :request_payload)
      payload_size = Ash.Changeset.get_attribute(changeset, :request_payload_size)

      assert payload_size == byte_size(payload_json)
      assert payload_size > 0
    end

    test "removes delivery from payload before encoding" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      payload_map = %{
        custom_id: custom_id,
        body: %{input: "test", model: model},
        method: "POST",
        url: url,
        delivery: %{type: "webhook", webhook_url: "https://example.com/webhook"},
        batch_id: batch.id
      }

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: payload_map,
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      payload_json = Ash.Changeset.get_attribute(changeset, :request_payload)
      decoded = JSON.decode!(payload_json)

      # Verify delivery and batch_id are removed
      refute Map.has_key?(decoded, "delivery")
      refute Map.has_key?(decoded, :delivery)
      refute Map.has_key?(decoded, "batch_id")
      refute Map.has_key?(decoded, :batch_id)

      # Verify other fields are present
      assert decoded["custom_id"] == custom_id
      assert decoded["body"]["model"] == model
      assert decoded["url"] == url
    end

    test "validates custom_id matches between attribute and payload" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: %{
            custom_id: "different_id",
            body: %{input: "test", model: model},
            method: "POST",
            url: url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn err ->
               err.field == :custom_id and String.contains?(err.message, "does not match")
             end)
    end

    test "validates model matches between attribute and payload" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: "different-model"},
            method: "POST",
            url: url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn err ->
               err.field == :model and String.contains?(err.message, "does not match")
             end)
    end

    test "validates url matches between attribute and payload" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: %{
            custom_id: custom_id,
            body: %{input: "test", model: model},
            method: "POST",
            url: "/v1/chat/completions"
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn err ->
               err.field == :url and String.contains?(err.message, "does not match")
             end)
    end

    test "does not set payload if changeset is invalid" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      # Create invalid changeset (mismatched custom_id)
      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: %{
            custom_id: "different_id",
            body: %{input: "test", model: model},
            method: "POST",
            url: url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      refute changeset.valid?
      # Payload should not be set when invalid
      assert Ash.Changeset.get_attribute(changeset, :request_payload) == nil
    end

    test "handles complex payload structures" do
      batch = generate(batch())
      custom_id = "test_req"
      model = batch.model
      url = batch.url

      payload_map = %{
        custom_id: custom_id,
        body: %{
          input: "What color is a grey Porsche?",
          model: model,
          temperature: 0.7,
          max_tokens: 100
        },
        method: "POST",
        url: url
      }

      changeset =
        Batching.Request
        |> Ash.Changeset.for_create(:create, %{
          batch_id: batch.id,
          custom_id: custom_id,
          url: url,
          model: model,
          request_payload: payload_map,
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        })

      changeset = SetPayload.change(changeset, [], %{})

      assert changeset.valid?
      payload_json = Ash.Changeset.get_attribute(changeset, :request_payload)
      decoded = JSON.decode!(payload_json)

      assert decoded["body"]["temperature"] == 0.7
      assert decoded["body"]["max_tokens"] == 100
    end
  end
end
