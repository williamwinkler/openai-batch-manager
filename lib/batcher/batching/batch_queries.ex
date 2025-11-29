defmodule Batcher.Batching.BatchQueries do
  @moduledoc """
  Database query helpers for batch operations.

  Provides optimized queries for counting requests, summing sizes, and other
  batch-related database operations.
  """

  @doc """
  Counts the number of requests in a batch.

  Uses SELECT COUNT(*) for optimal performance - does NOT load records.

  ## Examples

      iex> BatchQueries.count_requests_in_batch(123)
      42
  """
  def count_requests_in_batch(batch_id) do
    require Ash.Query

    Batcher.Batching.Request
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(batch_id == ^batch_id)
    |> Ash.count!()
  end

  @doc """
  Sums the request_payload_size for all requests in a batch.

  Only selects the size field for efficiency, then reduces to get the total.

  ## Examples

      iex> BatchQueries.sum_request_sizes_in_batch(123)
      10485760  # 10 MB
  """
  def sum_request_sizes_in_batch(batch_id) do
    require Ash.Query

    Batcher.Batching.Request
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(batch_id == ^batch_id)
    |> Ash.Query.select([:request_payload_size])
    |> Ash.read!()
    |> Enum.reduce(0, fn request, acc -> acc + request.request_payload_size end)
  end

  @doc """
  Computes the size of a request payload in bytes.

  Encodes the payload as JSON (matching how it will be stored in JSONL)
  and returns the byte size.

  ## Examples

      iex> BatchQueries.compute_payload_size(%{"model" => "gpt-4", "input" => "Hello"})
      35
  """
  def compute_payload_size(request_payload) when is_map(request_payload) do
    request_payload
    |> JSON.encode!()
    |> byte_size()
  end
end
