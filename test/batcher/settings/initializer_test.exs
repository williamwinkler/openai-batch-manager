defmodule Batcher.Settings.InitializerTest do
  use Batcher.DataCase, async: false

  alias Batcher.Settings.Initializer
  alias Batcher.Settings.Setting

  test "ensure_defaults creates singleton row only once" do
    assert :ok = Initializer.ensure_defaults()
    assert :ok = Initializer.ensure_defaults()

    all = Ash.read!(Setting)
    assert length(all) == 1
    assert hd(all).name == "openai_rate_limits"
  end
end
