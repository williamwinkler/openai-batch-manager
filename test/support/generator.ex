defmodule Batcher.Generator do
  @moduledoc "Data generation for tests"

  use Ash.Generator

  @doc """
  Generates batch changesets using the `:create` action.
  """
  def batch(opts \\ []) do
    url = opts[:url] || "/v1/responses"

    changeset_generator(
      Batcher.Batching.Batch,
      :create,
      defaults: [
        url: url,
        model: StreamData.repeatedly(fn -> Batcher.Models.model(url) end)
      ],
      overrides: opts
    )
  end


  @doc """
  Generates raw batch structs, bypassing the action logic.
  Useful for setting specific states.
  """
  def seeded_batch(opts \\ []) do
    url = opts[:url] || "/v1/responses"

    seed_generator(
      %Batcher.Batching.Batch{
        url: url,
        model: StreamData.repeatedly(fn -> Batcher.Models.model(url) end)
      },
      overrides: opts
    )
  end

  @doc """
  Generates request changesets using the `:create` action.
  """
  def request(opts \\ []) do
    url = opts[:url] || "/v1/responses"
    model = opts[:model] || Batcher.Models.model(url)

    batch_id =
      opts[:batch_id] ||
        once(:default_batch_id, fn ->
          generate(batch(model: model, url: url)).id
        end)

    StreamData.bind(sequence(:request_custom_id, &"custom_id_#{&1}"), fn cid ->
      changeset_generator(
        Batcher.Batching.Request,
        :create,
        defaults: [
          batch_id: batch_id,
          custom_id: cid,
          model: model,
          url: url,
          request_payload: %{
            :body => %{
              :input => "What color is a grey Porsche?",
              :model => model
            },
            :custom_id => cid,
            :method => "POST",
            :url => url
          },
          delivery: %{
            type: "webhook",
            webhook_url: "https://example.com/webhook"
          }
        ],
        overrides: opts
      )
    end)
  end

  @doc """
  Generates raw request structs, bypassing the action logic.
  Useful for setting specific states (e.g. :openai_processing).
  """
  def seeded_request(opts \\ []) do
    url = opts[:url] || "/v1/responses"
    model = opts[:model] || Batcher.Models.model(url)

    # Re-use the batch_id logic from your existing request generator
    batch_id =
      opts[:batch_id] ||
        once(:default_batch_id, fn ->
          generate(batch(model: model, url: url)).id
        end)

    # We need a default payload string because we are bypassing the
    # Change that normally calculates this.
    default_payload_map = %{
      body: %{input: "What color is a grey Porsche?", model: model},
      method: "POST",
      url: url
    }
    default_payload_json = JSON.encode!(default_payload_map)

    StreamData.bind(sequence(:seeded_req_id, &"custom_id_#{&1}"), fn cid ->
      # We must populate all "allow_nil?: false" attributes manually
      # because we aren't running the Create action's changes.
      seed_generator(
        %Batcher.Batching.Request{
          batch_id: batch_id,
          custom_id: cid,
          url: url,
          model: model,
          state: :pending, # Can be overridden by opts
          delivery_type: :webhook,
          webhook_url: "https://example.com/webhook",

          # IMPORTANT: The database expects these to be set,
          # but normally the action calculates them. We must fake them here.
          request_payload: default_payload_json,
          request_payload_size: byte_size(default_payload_json)
        },
        overrides: opts
      )
    end)
  end
end
