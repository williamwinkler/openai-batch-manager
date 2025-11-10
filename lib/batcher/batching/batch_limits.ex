defmodule Batcher.Batching.BatchLimits do
  @moduledoc """
  Centralized batch size limits and constraints.

  This module defines the OpenAI Batch API limits in one place to ensure
  consistency across validations and GenServer checks.
  Ref: https://platform.openai.com/docs/guides/batch
  """

  # 200 MB limit for batch JSONL files
  @max_batch_size_bytes 200 * 1024 * 1024
  # 50,000 prompts per batch
  @max_prompts_per_batch 50_000

  def max_batch_size_bytes, do: @max_batch_size_bytes
  def max_prompts_per_batch, do: @max_prompts_per_batch
end
