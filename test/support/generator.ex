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
          # Use the bound variable 'cid' in both places
          custom_id: cid,
          model: model,
          url: url,
          request_payload: %{
            :body => %{
              :input => "What color is a grey Porsche?",
              :model => model
            },
            :custom_id => cid, # <-- SAME VALUE HERE
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
end
