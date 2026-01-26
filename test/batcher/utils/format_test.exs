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
      assert Format.time_ago(now) == "0s ago"
      assert Format.time_ago(DateTime.add(now, -30, :second)) == "30s ago"
      assert Format.time_ago(DateTime.add(now, -59, :second)) == "59s ago"
    end

    test "shows minutes for times between 1-59 minutes ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -60, :second)) == "1m ago"
      assert Format.time_ago(DateTime.add(now, -120, :second)) == "2m ago"
      assert Format.time_ago(DateTime.add(now, -3599, :second)) == "59m ago"
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
      assert Format.time_ago(DateTime.add(now, -172800, :second)) == "2d ago"
      assert Format.time_ago(DateTime.add(now, -604799, :second)) == "6d ago"
    end

    test "shows weeks for times between 1-4 weeks ago" do
      now = DateTime.utc_now()
      # 604,800 seconds = 1 week
      assert Format.time_ago(DateTime.add(now, -604800, :second)) == "1w ago"
      # 1,209,600 seconds = 2 weeks
      assert Format.time_ago(DateTime.add(now, -1209600, :second)) == "2w ago"
      # 1,814,400 seconds = 3 weeks
      assert Format.time_ago(DateTime.add(now, -1814400, :second)) == "3w ago"
    end

    test "shows months for times between 1-11 months ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -2592000, :second)) == "1mo ago"
      assert Format.time_ago(DateTime.add(now, -5184000, :second)) == "2mo ago"
      assert Format.time_ago(DateTime.add(now, -31535999, :second)) == "12mo ago"
    end

    test "shows years for times 1+ years ago" do
      now = DateTime.utc_now()
      assert Format.time_ago(DateTime.add(now, -31536000, :second)) == "1y ago"
      assert Format.time_ago(DateTime.add(now, -63072000, :second)) == "2y ago"
      assert Format.time_ago(DateTime.add(now, -94608000, :second)) == "3y ago"
    end

    test "handles future times" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 100, :second)
      assert Format.time_ago(future) == "in the future"
    end
  end
end
