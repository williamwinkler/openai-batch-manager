defmodule Batcher.DoctestTest do
  use ExUnit.Case, async: true

  doctest Batcher.Utils.Format
  doctest Batcher.Batching.Validation.RequestValidator
  doctest Batcher.TokenEstimation.RequestEstimator
  doctest Batcher.TokenEstimation.TokenEstimator
  doctest Batcher.Clients.OpenAI.RateLimits
end
