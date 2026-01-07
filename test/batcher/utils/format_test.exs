defmodule Batcher.Utils.FormatTest do
  use ExUnit.Case, async: true

  alias Batcher.Utils.Format

  describe "bytes/1" do
    test "handles nil values" do
      assert Format.bytes(nil) == "0 bytes"
    end

    test "formats bytes (< 1024)" do
      assert Format.bytes(0) == "0 bytes"
      assert Format.bytes(500) == "500 bytes"
      assert Format.bytes(1023) == "1023 bytes"
    end

    test "formats KB (1024 - 1MB)" do
      assert Format.bytes(1024) == "1.0 KB"
      assert Format.bytes(2048) == "2.0 KB"
      assert Format.bytes(5120) == "5.0 KB"
      assert Format.bytes(1024 * 1024 - 1) == "1024.0 KB"
    end

    test "formats MB (1MB - 1GB)" do
      assert Format.bytes(1024 * 1024) == "1.0 MB"
      assert Format.bytes(2 * 1024 * 1024) == "2.0 MB"
      assert Format.bytes(100 * 1024 * 1024) == "100.0 MB"
      assert Format.bytes(1024 * 1024 * 1024 - 1) == "1024.0 MB"
    end

    test "formats GB (>= 1GB)" do
      assert Format.bytes(1024 * 1024 * 1024) == "1.0 GB"
      assert Format.bytes(2 * 1024 * 1024 * 1024) == "2.0 GB"
      assert Format.bytes(10 * 1024 * 1024 * 1024) == "10.0 GB"
    end

    test "handles exact boundaries" do
      # KB boundary
      assert Format.bytes(1023) == "1023 bytes"
      assert Format.bytes(1024) == "1.0 KB"

      # MB boundary
      assert Format.bytes(1024 * 1024 - 1) == "1024.0 KB"
      assert Format.bytes(1024 * 1024) == "1.0 MB"

      # GB boundary
      assert Format.bytes(1024 * 1024 * 1024 - 1) == "1024.0 MB"
      assert Format.bytes(1024 * 1024 * 1024) == "1.0 GB"
    end

    test "handles fractional sizes" do
      # 1.5 KB
      assert Format.bytes(1536) == "1.5 KB"

      # 1.5 MB
      assert Format.bytes(1536 * 1024) == "1.5 MB"

      # 1.5 GB
      assert Format.bytes(1536 * 1024 * 1024) == "1.5 GB"
    end

    test "rounds to 2 decimal places" do
      # 1.234 KB should round to 1.23 KB
      assert Format.bytes(1264) == "1.23 KB"

      # 1.999 MB should round to 2.0 MB
      assert Format.bytes(2_097_151) == "2.0 MB"
    end
  end
end
