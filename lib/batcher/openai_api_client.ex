defmodule Batcher.OpenaiApiClient do
  require Logger

  @doc """
  Uploads a file to OpenAI's file upload endpoint.
  """
  def upload_file(file_path) do
    openai_api_key = Application.fetch_env!(:batcher, :openai_api_key)

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

    url = "#{base_url()}/v1/files"

    Req.post(
      url,
      headers: headers,
      body: Multipart.body_stream(multipart)
    )
    |> handle_response()
  end

  @doc """
  Retrieves file information for a given file ID from OpenAI's platform.
  """
  def retrieve_file(file_id) do
    url = "#{base_url()}/v1/files/#{file_id}"

    Req.get(url, headers: headers())
    |> handle_response()
  end

  @doc """
  Deletes a file on OpenAI's platform given its file ID.
  """
  def delete_file(file_id) do
    url = "#{base_url()}/v1/files/#{file_id}"

    Req.delete(url, headers: headers())
    |> handle_response()
  end

  @doc """
    Creates a batch on OpenAI's platform using the provided file ID and endpoint.
  """
  def create_batch(input_file_id, endpoint, completion_window \\ "24h") do
    url = "#{base_url()}/v1/batches"

    Req.post(
      url,
      headers: headers(),
      json: %{
        input_file_id: input_file_id,
        endpoint: endpoint,
        completion_window: completion_window
      }
    )
    |> handle_response()
  end

  @doc """
  Cancels a batch on OpenAI's platform given its batch ID.
  """
  def cancel_batch(batch_id) do
    url = "#{base_url()}/v1/batches/#{batch_id}/cancel"

    Req.post(url, headers: headers())
    |> handle_response()
  end

  @doc """
  Checks the status of a batch on OpenAI's platform given its batch ID.
  """
  def check_batch_status("batch_" <> _ = batch_id) do
    url = "#{base_url()}/v1/batches/#{batch_id}"

    Req.get(url, headers: headers())
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

  defp handle_response(response) do
    case response do
      {:ok, %{status: status, body: body}} when 200 >= status and status < 300 ->
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

  defp headers() do
    api_key = Application.fetch_env!(:batcher, :openai_api_key)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end
end
