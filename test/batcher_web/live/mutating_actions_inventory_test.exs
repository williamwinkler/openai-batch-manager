defmodule BatcherWeb.MutatingActionsInventoryTest do
  use ExUnit.Case, async: true

  @batch_index_file "lib/batcher_web/live/batch_index_live.ex"
  @batch_show_file "lib/batcher_web/live/batch_show_live.ex"
  @request_show_file "lib/batcher_web/live/request_show_live.ex"
  @settings_file "lib/batcher_web/live/settings_live.ex"

  test "mutating action entrypoints use shared async helper" do
    batch_index = File.read!(@batch_index_file)
    batch_show = File.read!(@batch_show_file)
    request_show = File.read!(@request_show_file)
    settings = File.read!(@settings_file)

    assert batch_index =~ ~s(defp start_batch_action_async)
    assert batch_index =~ ~s(AsyncActions.start_shared_action)

    assert batch_show =~ ~s(defp start_current_batch_action_async)
    assert batch_show =~ ~s(AsyncActions.start_shared_action)

    assert request_show =~ ~s(def handle_event("retry_delivery")
    assert request_show =~ ~s(def handle_event("delete_request")
    assert request_show =~ ~s(def handle_event("save_delivery_config")
    assert request_show =~ ~s(AsyncActions.start_shared_action)

    assert settings =~ ~s(def handle_event("save_override")
    assert settings =~ ~s(def handle_event("delete_override")
    assert settings =~ ~s(AsyncActions.start_shared_action)
  end

  test "state-change handle_info paths avoid synchronous get-by-id bang calls" do
    batch_show = File.read!(@batch_show_file)
    request_show = File.read!(@request_show_file)

    refute batch_show =~ ~s(%{topic: "batches:state_changed:) <> ~s(Batching.get_batch_by_id!)

    refute request_show =~
             ~s(%{topic: "requests:state_changed:) <> ~s(Batching.get_request_by_id!)

    assert batch_show =~ ~s(start_async({:batch_refresh,)
    assert request_show =~ ~s(start_async({:request_refresh,)
  end
end
