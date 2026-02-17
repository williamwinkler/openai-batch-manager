defmodule Batcher.DoctestTest do
  use ExUnit.Case, async: true

  doctest Batcher.TokenEstimator
  doctest Batcher.OpenaiRateLimits
end
