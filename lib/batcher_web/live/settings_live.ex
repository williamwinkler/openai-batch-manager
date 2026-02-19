defmodule BatcherWeb.SettingsLive do
  use BatcherWeb, :live_view

  require Logger

  alias Batcher.OpenaiRateLimits
  alias Batcher.Settings
  alias BatcherWeb.Live.Utils.AsyncActions
  alias Batcher.Utils.Format

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.ensure_rate_limit_settings!()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:pending_actions, MapSet.new())
     |> assign(:settings, settings)
     |> assign(:overrides, Settings.list_model_overrides!())
     |> assign(:model_suggestions, model_suggestions())
     |> assign(:model_default_limits, model_default_limits())
     |> assign(:token_limit_preview, nil)
     |> assign_override_form(build_override_form(settings))}
  end

  @impl true
  def handle_event("validate_override", %{"override" => params}, socket) do
    normalized_params = normalize_override_params(params)
    form = AshPhoenix.Form.validate(socket.assigns.override_ash_form, normalized_params)

    {:noreply,
     socket
     |> assign(:token_limit_preview, compact_preview(normalized_params["token_limit"]))
     |> assign_override_form(form)}
  end

  @impl true
  def handle_event("save_override", %{"override" => params}, socket) do
    normalized_params = normalize_override_params(params)
    key = {:settings_action, :save_override}
    override_ash_form = socket.assigns.override_ash_form

    AsyncActions.start_action(socket, key, fn ->
      maybe_test_async_delay()

      case AshPhoenix.Form.submit(override_ash_form, params: normalized_params) do
        {:ok, updated_settings} ->
          {:ok, %{type: :save_override, settings: updated_settings}}

        {:error, form} ->
          {:error,
           %{message: "Please fix the form errors", form: form, params: normalized_params}}
      end
    end)
  end

  @impl true
  def handle_event("delete_override", %{"model_prefix" => model_prefix}, socket) do
    key = {:settings_action, :delete_override, model_prefix}

    AsyncActions.start_action(socket, key, fn ->
      maybe_test_async_delay()
      updated_settings = Settings.delete_model_override!(model_prefix)
      {:ok, %{type: :delete_override, settings: updated_settings}}
    end)
  end

  @impl true
  def handle_event("erase_db", _params, socket) do
    key = {:settings_action, :erase_db}

    AsyncActions.start_action(socket, key, fn ->
      maybe_test_async_delay()
      Logger.info("Settings erase_db requested")

      case data_reset_module().erase_all() do
        :ok ->
          settings = Settings.ensure_rate_limit_settings!()
          {:ok, %{type: :erase_db, settings: settings}}

        {:error, reason} ->
          Logger.error("Failed to erase database from settings liveview: #{inspect(reason)}")
          {:error, "Failed to erase database: #{exception_message(reason)}"}
      end
    end)
  end

  @impl true
  def handle_async({:settings_action, action}, {:ok, result}, socket) do
    socket = AsyncActions.clear_pending(socket, {:settings_action, action})
    {:noreply, apply_settings_action_result(socket, result)}
  end

  @impl true
  def handle_async({:settings_action, action, model_prefix}, {:ok, result}, socket) do
    socket = AsyncActions.clear_pending(socket, {:settings_action, action, model_prefix})
    {:noreply, apply_settings_action_result(socket, result)}
  end

  @impl true
  def handle_async({:settings_action, action}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> AsyncActions.clear_pending({:settings_action, action})
     |> put_flash(:error, "Action failed unexpectedly: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:settings_action, action, model_prefix}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> AsyncActions.clear_pending({:settings_action, action, model_prefix})
     |> put_flash(:error, "Action failed unexpectedly: #{inspect(reason)}")}
  end

  defp build_override_form(settings) do
    AshPhoenix.Form.for_update(settings, :upsert_model_override,
      as: "override",
      domain: Settings,
      forms: [],
      params: %{"model_prefix" => "", "token_limit" => ""}
    )
  end

  defp assign_override_form(socket, form) do
    socket
    |> assign(:override_ash_form, form)
    |> assign(:override_form, to_form(form))
  end

  defp normalize_override_params(params) when is_map(params) do
    params
    |> Map.update("model_prefix", "", &String.trim/1)
    |> Map.update("token_limit", "", &sanitize_token_limit/1)
  end

  defp sanitize_token_limit(value) do
    value
    |> to_string()
    |> String.replace(~r/[^\d]/u, "")
  end

  defp compact_preview(""), do: nil

  defp compact_preview(token_limit) do
    case Integer.parse(token_limit) do
      {value, ""} when value > 0 -> Format.compact_number(value)
      _ -> nil
    end
  end

  defp model_suggestions do
    OpenaiRateLimits.model_prefix_suggestions()
    |> Enum.uniq()
  end

  defp model_default_limits do
    OpenaiRateLimits.model_prefix_default_limits()
  end

  defp data_reset_module do
    Application.get_env(:batcher, :data_reset_module, Batcher.Storage.DataReset)
  end

  defp exception_message(%{message: message}) when is_binary(message), do: message
  defp exception_message(reason) when is_binary(reason), do: reason
  defp exception_message(reason), do: inspect(reason)

  def pending_action?(pending_actions, action) do
    AsyncActions.pending?(pending_actions, {:settings_action, action})
  end

  def pending_action?(pending_actions, action, model_prefix) do
    AsyncActions.pending?(pending_actions, {:settings_action, action, model_prefix})
  end

  def format_token_cap(token_limit) when is_integer(token_limit) and token_limit >= 0 do
    "#{format_with_delimiters(token_limit)} (#{Format.compact_number(token_limit)})"
  end

  defp format_with_delimiters(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/u, ",")
  end

  defp apply_settings_action_result(
         socket,
         {:ok, %{type: :save_override, settings: updated_settings}}
       ) do
    socket
    |> put_flash(:info, "Override saved")
    |> assign(:settings, updated_settings)
    |> assign(:overrides, Settings.list_model_overrides!())
    |> assign(:token_limit_preview, nil)
    |> assign_override_form(build_override_form(updated_settings))
  end

  defp apply_settings_action_result(
         socket,
         {:ok, %{type: :delete_override, settings: updated_settings}}
       ) do
    socket
    |> put_flash(:info, "Override removed")
    |> assign(:overrides, Settings.list_model_overrides!())
    |> assign(:settings, updated_settings)
    |> assign(:token_limit_preview, nil)
    |> assign_override_form(build_override_form(updated_settings))
  end

  defp apply_settings_action_result(socket, {:ok, %{type: :erase_db, settings: settings}}) do
    socket
    |> put_flash(:info, "Database erased successfully")
    |> assign(:settings, settings)
    |> assign(:overrides, Settings.list_model_overrides!())
    |> assign(:token_limit_preview, nil)
    |> assign_override_form(build_override_form(settings))
  end

  defp apply_settings_action_result(
         socket,
         {:error, %{message: message, form: form, params: normalized_params}}
       ) do
    socket
    |> put_flash(:error, message)
    |> assign(:token_limit_preview, compact_preview(normalized_params["token_limit"]))
    |> assign_override_form(form)
  end

  defp apply_settings_action_result(socket, {:error, message}) when is_binary(message) do
    put_flash(socket, :error, message)
  end

  defp maybe_test_async_delay do
    case Application.get_env(:batcher, :batch_action_test_delay_ms, 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end
end
