# priv/scripts/http_requests.exs

for _i <- 1..10 do
  req = %{
    "body" => %{
      "input" => "Say 'hi' back",
      "model" => "gpt-4o-mini"
    },
    "custom_id" => Ecto.UUID.generate(),
    "delivery" => %{
      "type" => "webhook",
      "webhook_url" => "https://api.example.com/webhook?auth=secret"
    },
    "method" => "POST",
    "url" => "/v1/responses"
  }

  Req.post!(
    "http://localhost:4000/api/requests",
    json: req,
    headers: [{"content-type", "application/json"}]
  )
end
