defmodule BatcherWeb.BatchFileController do
  use BatcherWeb, :controller

  alias Batcher.Batching
  alias Batcher.OpenaiApiClient

  @valid_file_types %{
    "input" => :openai_input_file_id,
    "output" => :openai_output_file_id,
    "error" => :openai_error_file_id
  }

  def download(conn, %{"batch_id" => batch_id, "file_type" => file_type}) do
    with {:ok, field} <- validate_file_type(file_type),
         {:ok, parsed_batch_id} <- parse_batch_id(batch_id),
         {:ok, batch} <- Batching.get_batch_by_id(parsed_batch_id),
         {:ok, file_id} <- extract_file_id(batch, field),
         {:ok, content} <- OpenaiApiClient.get_file_content(file_id) do
      filename = "#{file_id}.jsonl"

      conn
      |> put_resp_content_type("application/jsonl")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, content)
    else
      {:error, :invalid_file_type} ->
        conn |> put_flash(:error, "Invalid file type") |> redirect(to: referer_or_home(conn))

      {:error, :invalid_batch_id} ->
        conn |> put_flash(:error, "Invalid batch id") |> redirect(to: referer_or_home(conn))

      {:error, :no_file_id} ->
        conn
        |> put_flash(:error, "No #{file_type} file available for this batch")
        |> redirect(to: referer_or_home(conn))

      {:error, :not_found} ->
        conn |> put_flash(:error, "File not found") |> redirect(to: referer_or_home(conn))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to download file from OpenAI")
        |> redirect(to: referer_or_home(conn))
    end
  end

  defp validate_file_type(file_type) do
    case Map.fetch(@valid_file_types, file_type) do
      {:ok, field} -> {:ok, field}
      :error -> {:error, :invalid_file_type}
    end
  end

  defp parse_batch_id(batch_id) when is_binary(batch_id) do
    case Integer.parse(batch_id) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_batch_id}
    end
  end

  defp parse_batch_id(_), do: {:error, :invalid_batch_id}

  defp extract_file_id(batch, field) do
    case Map.get(batch, field) do
      nil -> {:error, :no_file_id}
      file_id -> {:ok, file_id}
    end
  end

  defp referer_or_home(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] ->
        uri = URI.parse(referer)
        uri.path || "/"

      _ ->
        "/"
    end
  end
end
