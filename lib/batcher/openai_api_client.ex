defmodule Batcher.OpenaiApiClient do
  require Logger

  @doc """
  Uploads a file to OpenAI's file upload endpoint.
  """
  def upload_file(file_path) do
    multipart =
      Multipart.new()
      |> Multipart.add_part(Multipart.Part.text_field("batch", "purpose"))
      |> Multipart.add_part(Multipart.Part.file_field(file_path, :file))

    content_length = Multipart.content_length(multipart)
    content_type = Multipart.content_type(multipart, "multipart/form-data")

    headers = [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", content_type},
      {"Content-Length", to_string(content_length)}
    ]

    url = "#{base_url()}/v1/files"

    retry_opts = retry_options()
    timeout_opts = timeout_options()

    Req.post(
      url,
      headers: headers,
      body: Multipart.body_stream(multipart),
      # File uploads can be slow - use generous timeouts in production
      pool_timeout: timeout_opts[:pool_timeout],
      receive_timeout: timeout_opts[:receive_timeout],
      connect_options: [timeout: timeout_opts[:connect_timeout]],
      # Retry on transient network errors (connection closed, timeout, etc.)
      retry: retry_opts[:retry],
      max_retries: retry_opts[:max_retries],
      retry_delay: retry_opts[:retry_delay]
    )
    |> handle_response()
  end

  @doc """
  Retrieves file information for a given file ID from OpenAI's platform.
  """
  def retrieve_file_metadata(file_id) do
    url = "#{base_url()}/v1/files/#{file_id}"
    timeout_opts = timeout_options()
    retry_opts = retry_options()

    Req.get(url,
      headers: headers(),
      pool_timeout: timeout_opts[:pool_timeout],
      receive_timeout: timeout_opts[:receive_timeout],
      connect_options: [timeout: timeout_opts[:connect_timeout]],
      retry: retry_opts[:retry],
      max_retries: retry_opts[:max_retries],
      retry_delay: retry_opts[:retry_delay]
    )
    |> handle_response()
  end

  @doc """
  Downloads a file by id

  Returns:
   {:ok, file_path}
   {:error, reason}
  """
  def download_file(file_id, output_dir \\ "data/batches/outputs") do
    url = "#{base_url()}/v1/files/#{file_id}/content"

    dest_path = Path.join(output_dir, "#{file_id}.jsonl")

    # Ensure output directory exists
    File.mkdir_p!(output_dir)

    timeout_opts = timeout_options()
    retry_opts = retry_options()

    case Req.get(url,
           headers: headers(),
           into: File.stream!(dest_path),
           pool_timeout: timeout_opts[:pool_timeout],
           receive_timeout: timeout_opts[:receive_timeout],
           connect_options: [timeout: timeout_opts[:connect_timeout]],
           retry: retry_opts[:retry],
           max_retries: retry_opts[:max_retries],
           retry_delay: retry_opts[:retry_delay]
         ) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        {:ok, dest_path}

      {:ok, %{status: status}} when status >= 500 ->
        # Clean up partial file on server error
        File.rm(dest_path)
        Logger.error("OpenAI download failed with server error: HTTP #{status}")
        {:error, :server_error}

      {:ok, %{status: 404}} ->
        File.rm(dest_path)
        {:error, :not_found}

      {:ok, %{status: 401}} ->
        File.rm(dest_path)
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        File.rm(dest_path)
        Logger.error("OpenAI download failed: HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads file content from OpenAI as an in-memory binary.

  Returns:
    {:ok, binary}
    {:error, reason}
  """
  def get_file_content(file_id) do
    url = "#{base_url()}/v1/files/#{file_id}/content"
    timeout_opts = timeout_options()
    retry_opts = retry_options()

    case Req.get(url,
           headers: headers(),
           pool_timeout: timeout_opts[:pool_timeout],
           receive_timeout: timeout_opts[:receive_timeout],
           connect_options: [timeout: timeout_opts[:connect_timeout]],
           retry: retry_opts[:retry],
           max_retries: retry_opts[:max_retries],
           retry_delay: retry_opts[:retry_delay]
         ) do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} when status >= 500 ->
        Logger.error("OpenAI file content download failed with server error: HTTP #{status}")
        {:error, :server_error}

      {:ok, %{status: status}} ->
        Logger.error("OpenAI file content download failed: HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("OpenAI file content request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  @doc """
  Deletes a file on OpenAI's platform given its file ID.
  """
  def delete_file(file_id) do
    url = "#{base_url()}/v1/files/#{file_id}"
    timeout_opts = timeout_options()

    Req.delete(url,
      headers: headers(),
      pool_timeout: timeout_opts[:pool_timeout],
      receive_timeout: timeout_opts[:receive_timeout],
      connect_options: [timeout: timeout_opts[:connect_timeout]]
    )
    |> handle_response()
  end

  @doc """
    Creates a batch on OpenAI's platform using the provided file ID and endpoint.
  """
  def create_batch(input_file_id, endpoint, completion_window \\ "24h") do
    url = "#{base_url()}/v1/batches"
    timeout_opts = timeout_options()

    Req.post(
      url,
      headers: headers(),
      json: %{
        input_file_id: input_file_id,
        endpoint: endpoint,
        completion_window: completion_window
      },
      pool_timeout: timeout_opts[:pool_timeout],
      receive_timeout: timeout_opts[:receive_timeout],
      connect_options: [timeout: timeout_opts[:connect_timeout]]
    )
    |> handle_response()
  end

  @doc """
  Cancels a batch on OpenAI's platform given its batch ID.
  """
  def cancel_batch(batch_id) do
    url = "#{base_url()}/v1/batches/#{batch_id}/cancel"
    timeout_opts = timeout_options()

    Req.post(url,
      headers: headers(),
      pool_timeout: timeout_opts[:pool_timeout],
      receive_timeout: timeout_opts[:receive_timeout],
      connect_options: [timeout: timeout_opts[:connect_timeout]]
    )
    |> handle_response()
  end

  @doc """
  Checks the status of a batch on OpenAI's platform given its batch ID.
  """
  def check_batch_status("batch_" <> _ = batch_id) do
    url = "#{base_url()}/v1/batches/#{batch_id}"
    timeout_opts = timeout_options()
    retry_opts = retry_options()

    Req.get(url,
      headers: headers(),
      pool_timeout: timeout_opts[:pool_timeout],
      receive_timeout: timeout_opts[:receive_timeout],
      connect_options: [timeout: timeout_opts[:connect_timeout]],
      retry: retry_opts[:retry],
      max_retries: retry_opts[:max_retries],
      retry_delay: retry_opts[:retry_delay]
    )
    |> handle_response()
  end

  def extract_token_usage_from_batch_status(batch_response) do
    %{
      "input_tokens" => input_tokens,
      "input_tokens_details" => %{"cached_tokens" => cached_tokens},
      "output_tokens_details" => %{"reasoning_tokens" => reasoning_tokens},
      "output_tokens" => output_tokens
    } = batch_response["usage"] || %{}

    %{
      input_tokens: input_tokens || 0,
      cached_tokens: cached_tokens || 0,
      reasoning_tokens: reasoning_tokens || 0,
      output_tokens: output_tokens || 0
    }
  end

  @doc """
  Validates the OpenAI API key by making a lightweight API call.

  - On success (HTTP 200): logs confirmation and returns :ok
  - On auth failure (HTTP 401): logs error details and raises, stopping the application
  - On other HTTP status: logs a warning and returns :ok (key may still be valid)
  - On network error: logs a warning and returns :ok (OpenAI may be temporarily unreachable)
  """
  def validate_api_key! do
    Logger.info("Validating OpenAI API key against OpenAI API...")

    url = "#{base_url()}/v1/models"

    case Req.get(url,
           headers: headers(),
           params: [limit: 1],
           connect_options: [timeout: 5_000],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: 200}} ->
        Logger.info("OpenAI API key is valid")
        :ok

      {:ok, %{status: 401, body: body}} ->
        Logger.error("""
        OpenAI API key validation failed: unauthorized (HTTP 401)
        Response body: #{inspect(body)}
        Please verify your OPENAI_API_KEY environment variable is set to a valid key.
        """)

        raise "Invalid OpenAI API key: authentication failed (HTTP 401). " <>
                "The application cannot function without a valid key. " <>
                "Check your OPENAI_API_KEY environment variable."

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "OpenAI API key validation returned unexpected status #{status}: #{inspect(body)}. " <>
            "Continuing startup — the key may still be valid."
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not reach OpenAI to validate API key: #{inspect(reason)}. " <>
            "Continuing startup — OpenAI may be temporarily unreachable."
        )

        :ok
    end
  end

  defp handle_response(response) do
    case response do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %{status: 400, body: body}} ->
        Logger.info("Bad request: #{inspect(body)}")
        {:error, {:bad_request, body}}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} when status >= 500 ->
        Logger.error("OpenAI server error: HTTP #{status}")
        {:error, :server_error}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("OpenAI request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp base_url() do
    default = Application.get_env(:openai, __MODULE__)[:base_url] || "https://api.openai.com"

    ProcessTree.get(:openai_base_url, default: default)
  end

  defp api_key() do
    Application.fetch_env!(:batcher, __MODULE__)[:openai_api_key]
  end

  defp headers() do
    [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp retry_options() do
    if Application.get_env(:batcher, :disable_http_retries, false) do
      [retry: false, max_retries: 0, retry_delay: nil]
    else
      [retry: :transient, max_retries: 3, retry_delay: fn attempt -> attempt * 1000 end]
    end
  end

  defp timeout_options() do
    # Use configurable timeouts - low for tests, generous for production
    http_timeouts = Application.get_env(:batcher, :http_timeouts, [])

    %{
      pool_timeout: Keyword.get(http_timeouts, :pool_timeout, 30_000),
      receive_timeout: Keyword.get(http_timeouts, :receive_timeout, 120_000),
      connect_timeout: Keyword.get(http_timeouts, :connect_timeout, 10_000)
    }
  end
end
