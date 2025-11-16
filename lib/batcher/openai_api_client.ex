defmodule Batcher.OpenaiApiClient do
  require Logger

  @doc """
  Uploads a file to OpenAI's file upload endpoint.
  """
  def upload_file(file_path) do
    openai_api_key = Application.fetch_env!(:batcher, :openai_api_key)
    file_name = Path.basename(file_path)

    multipart =
      Multipart.new()
      |> Multipart.add_part(Multipart.Part.text_field("batch", "purpose"))
      |> Multipart.add_part(Multipart.Part.file_field(file_path, :file))

    content_length = Multipart.content_length(multipart)
    content_type = Multipart.content_type(multipart, "multipart/form-data")

    headers = [
      {"Authorization", "Bearer #{openai_api_key}"},
      {"Content-Type", content_type},
      {"Content-Length", to_string(content_length)}
    ]

    Logger.info("Started uploading #{file_name}")

    case Req.post(
           "https://api.openai.com/v1/files",
           headers: headers,
           body: Multipart.body_stream(multipart)
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Successfully uploaded #{file_name}")
        {:ok, body}

      {:ok, %{status: status, body: %{"error" => error}}} ->
        error_msg = "OpenAI file upload error (#{status}): #{error["message"]}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:ok, %{status: status}} ->
        error_msg = "HTTP error #{status}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:error, reason} ->
        error_msg = "Request failed: #{inspect(reason)}"
        Logger.error(error_msg)
        {:error, error_msg}
    end
  end

  @doc """
  Retrieves file information for a given file ID from OpenAI's platform.
  """
  def retrieve_file("file-" <> _ = file_id), do: do_retrieve_file(file_id)
  def retrieve_file(_invalid_id), do: {:error, :invalid_file_id}

  defp do_retrieve_file(file_id) do
    openai_api_key = Application.fetch_env!(:batcher, :openai_api_key)

    case Req.get(
           "https://api.openai.com/v1/files/#{file_id}",
           headers: [
             {"Authorization", "Bearer #{openai_api_key}"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        error_msg = "HTTP error #{status}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:error, reason} ->
        error_msg = "Request failed: #{inspect(reason)}"
        Logger.error(error_msg)
        {:error, error_msg}
    end
  end

  @doc """
  Deletes a file on OpenAI's platform given its file ID.
  """
  def delete_file("file-" <> _ = file_id) do
    openai_api_key = Application.fetch_env!(:batcher, :openai_api_key)

    case Req.delete(
           "https://api.openai.com/v1/files/#{file_id}",
           headers: [
             {"Authorization", "Bearer #{openai_api_key}"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        error_msg = "HTTP error #{status}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:error, reason} ->
        error_msg = "Request failed: #{inspect(reason)}"
        Logger.error(error_msg)
        {:error, error_msg}
    end
  end

  @doc """
    Creates a batch on OpenAI's platform using the provided file ID and endpoint.
  """
  def create_batch(file_id, endpoint, completion_window \\ "24h")

  def create_batch("file-" <> _ = file_id, "/" <> _ = endpoint, completion_window) do
    do_create_batch(file_id, endpoint, completion_window)
  end

  def create_batch(file_id, endpoint, _completion_window) do
    cond do
      not String.starts_with?(file_id, "file-") -> {:error, :invalid_file_id}
      not String.starts_with?(endpoint, "/") -> {:error, :invalid_endpoint}
      true -> {:error, :invalid_arguments}
    end
  end

  defp do_create_batch(file_id, endpoint, completion_window) do
    openai_api_key = Application.fetch_env!(:batcher, :openai_api_key)

    Logger.debug("Creating OpenAI batch with file_id: #{file_id}, endpoint: #{endpoint}")

    case Req.post(
           "https://api.openai.com/v1/batches",
           headers: [
             {"Authorization", "Bearer #{openai_api_key}"},
             {"Content-Type", "application/json"}
           ],
           json: %{
             input_file_id: file_id,
             endpoint: endpoint,
             completion_window: completion_window
           }
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Successfully created OpenAI batch: #{body["id"]}")
        {:ok, body}

      {:ok, %{status: status, body: %{"error" => error}}} ->
        error_msg = "OpenAI batch creation error (#{status}): #{error["message"]}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:ok, %{status: status}} ->
        error_msg = "HTTP error #{status}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:error, reason} ->
        error_msg = "Request failed: #{inspect(reason)}"
        Logger.error(error_msg)
        {:error, error_msg}
    end
  end

  @doc """
  Cancels a batch on OpenAI's platform given its batch ID.
  """
  def cancel_batch("batch_" <> _ = batch_id) do
    openai_api_key = Application.fetch_env!(:batcher, :openai_api_key)

    case Req.post(
           "https://api.openai.com/v1/batches/#{batch_id}/cancel",
           headers: [
             {"Authorization", "Bearer #{openai_api_key}"},
             {"Content-Type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Successfully canceled OpenAI batch: #{batch_id}")
        {:ok, body}

      {:ok, %{status: status, body: %{"error" => error}}} ->
        error_msg = "OpenAI batch cancellation error (#{status}): #{error["message"]}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:ok, %{status: status}} ->
        error_msg = "HTTP error #{status}"
        Logger.error(error_msg)
        {:error, error_msg}

      {:error, reason} ->
        error_msg = "Request failed: #{inspect(reason)}"
        Logger.error(error_msg)
        {:error, error_msg}
    end
  end
end
