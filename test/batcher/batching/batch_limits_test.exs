defmodule Batcher.Batching.BatchLimitsTest do
  use Batcher.DataCase, async: true

  alias Batcher.Batching.BatchLimits

  describe "max_batch_size_bytes/0" do
    test "returns 200MB in bytes" do
      assert BatchLimits.max_batch_size_bytes() == 200 * 1024 * 1024
      assert BatchLimits.max_batch_size_bytes() == 209_715_200
    end
  end

  describe "max_requests_per_batch/0" do
    test "returns 50,000" do
      assert BatchLimits.max_requests_per_batch() == 50_000
    end
  end
end
