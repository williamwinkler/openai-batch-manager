defmodule BatcherWeb.SettingsLive do
  use BatcherWeb, :live_view

  alias Batcher.OpenaiRateLimits
  alias Batcher.Settings
  alias Batcher.Utils.Format

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.ensure_rate_limit_settings!()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
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

    case AshPhoenix.Form.submit(socket.assigns.override_ash_form, params: normalized_params) do
      {:ok, updated_settings} ->
        {:noreply,
         socket
         |> put_flash(:info, "Override saved")
         |> assign(:settings, updated_settings)
         |> assign(:overrides, Settings.list_model_overrides!())
         |> assign(:token_limit_preview, nil)
         |> assign_override_form(build_override_form(updated_settings))}

      {:error, form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the form errors")
         |> assign(:token_limit_preview, compact_preview(normalized_params["token_limit"]))
         |> assign_override_form(form)}
    end
  end

  @impl true
  def handle_event("delete_override", %{"model_prefix" => model_prefix}, socket) do
    updated_settings = Settings.delete_model_override!(model_prefix)

    {:noreply,
     socket
     |> put_flash(:info, "Override removed")
     |> assign(:overrides, Settings.list_model_overrides!())
     |> assign(:settings, updated_settings)
     |> assign(:token_limit_preview, nil)
     |> assign_override_form(build_override_form(updated_settings))}
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

  def format_token_cap(token_limit) when is_integer(token_limit) and token_limit >= 0 do
    "#{format_with_delimiters(token_limit)} (#{Format.compact_number(token_limit)})"
  end

  defp format_with_delimiters(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/u, ",")
  end
end
