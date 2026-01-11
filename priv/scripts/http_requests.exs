# priv/scripts/http_requests.exs

# Helper function to generate random model
random_model = fn ->
  Enum.random([
    "gpt-4o-mini",
    "gpt-4o",
    "gpt-4.1-mini",
    "gpt-4.1",
    "gpt-5",
    "gpt-5-mini",
    "gpt-5.1",
    "gpt-5.2",
    "o3-mini",
    "o3",
    "o4-mini",
    "o4"
  ])
end

_ = random_model

for _i <- 1..50_001 do
  req = %{
    "body" => %{
      "input" => "Analyze the following product review and extract key information: 'I bought this laptop last month and it's been amazing! The battery lasts 10 hours, the screen is crystal clear, and it runs all my apps smoothly. The only downside is it's a bit heavy at 2.5kg. Overall rating: 4.5/5 stars.'",
      "model" => "gpt-4o-mini",
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "product_review_analysis",
          "schema" => %{
            "type" => "object",
            "properties" => %{
              "rating" => %{
                "type" => "number",
                "description" => "Overall rating out of 5"
              },
              "sentiment" => %{
                "type" => "string",
                "enum" => ["positive", "negative", "neutral"],
                "description" => "Overall sentiment of the review"
              },
              "features" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "name" => %{
                      "type" => "string",
                      "description" => "Feature name"
                    },
                    "sentiment" => %{
                      "type" => "string",
                      "enum" => ["positive", "negative", "neutral"]
                    },
                    "details" => %{
                      "type" => "array",
                      "items" => %{
                        "type" => "string"
                      }
                    }
                  },
                  "required" => ["name", "sentiment", "details"],
                  "additionalProperties" => false
                },
                "description" => "List of features mentioned in the review"
              },
              "specifications" => %{
                "type" => "object",
                "properties" => %{
                  "weight" => %{
                    "type" => "string",
                    "description" => "Product weight if mentioned"
                  },
                  "battery_life" => %{
                    "type" => "string",
                    "description" => "Battery life if mentioned"
                  }
                },
                "required" => ["weight", "battery_life"],
                "additionalProperties" => false
              }
            },
            "required" => ["rating", "sentiment", "features", "specifications"],
            "additionalProperties" => false
          }
        }
      }
    },
    "custom_id" => Ecto.UUID.generate(),
    "delivery_config" => %{
      "type" => "webhook",
      "webhook_url" => "https://webhook.site/737a3db4-1de7-429e-aae6-6239a3582fe9"
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
