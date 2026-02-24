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

  describe "time_ago/1" do
    test "handles nil values" do
      assert Format.time_ago(nil) == "—"
    end

    test "shows seconds for recent times" do
      now = DateTime.utc_now()
      assert Format.time_ago(now) == "<1m ago"
      assert Format.time_ago(DateTime.add(now, -30, :second)) == "<1m ago"
      assert Format.time_ago(DateTime.add(now, -59, :second)) == "<1m ago"
    end

    test "shows minutes for times between 1-59 minutes ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -60, :second)) == "1m ago"
      assert Format.time_ago(DateTime.add(now, -120, :second)) == "2m ago"
      assert Format.time_ago(DateTime.add(now, -3540, :second)) == "59m ago"
    end

    test "shows hours for times between 1-23 hours ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -3600, :second)) == "1h ago"
      assert Format.time_ago(DateTime.add(now, -7200, :second)) == "2h ago"
      assert Format.time_ago(DateTime.add(now, -86399, :second)) == "23h ago"
    end

    test "shows days for times between 1-6 days ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -86400, :second)) == "1d ago"
      assert Format.time_ago(DateTime.add(now, -172_800, :second)) == "2d ago"
      assert Format.time_ago(DateTime.add(now, -604_799, :second)) == "6d ago"
    end

    test "shows weeks for times between 1-4 weeks ago" do
      now = DateTime.utc_now()
      # 604,800 seconds = 1 week
      assert Format.time_ago(DateTime.add(now, -604_800, :second)) == "1w ago"
      # 1,209,600 seconds = 2 weeks
      assert Format.time_ago(DateTime.add(now, -1_209_600, :second)) == "2w ago"
      # 1,814,400 seconds = 3 weeks
      assert Format.time_ago(DateTime.add(now, -1_814_400, :second)) == "3w ago"
    end

    test "shows months for times between 1-11 months ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -2_592_000, :second)) == "1mo ago"
      assert Format.time_ago(DateTime.add(now, -5_184_000, :second)) == "2mo ago"
      assert Format.time_ago(DateTime.add(now, -31_535_999, :second)) == "12mo ago"
    end

    test "shows years for times 1+ years ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -31_536_000, :second)) == "1y ago"
      assert Format.time_ago(DateTime.add(now, -63_072_000, :second)) == "2y ago"
      assert Format.time_ago(DateTime.add(now, -94_608_000, :second)) == "3y ago"
    end

    test "handles future times" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 100, :second)
      assert Format.time_ago(future) == "in the future"
    end
  end

  describe "duration_since/1" do
    test "handles nil values" do
      assert Format.duration_since(nil) == ""
    end

    test "handles DateTime values" do
      now = DateTime.utc_now()
      assert Format.duration_since(DateTime.add(now, -30, :second)) == "less than 1m ago"
      assert Format.duration_since(DateTime.add(now, -120, :second)) == "2m"
    end

    test "handles NaiveDateTime values as UTC" do
      naive =
        DateTime.utc_now()
        |> DateTime.add(-75, :second)
        |> DateTime.to_naive()

      assert Format.duration_since(naive) == "1m"
    end

    test "handles unsupported input types safely" do
      assert Format.duration_since("invalid") == ""
    end
  end
end
