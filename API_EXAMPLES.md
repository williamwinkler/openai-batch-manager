# POST /v1/prompt - API Examples

The `/api/json/prompt` endpoint accepts three different request body types, discriminated by the `endpoint` field.

## Common Requirements

All request bodies must include:
- `custom_id` (string) - Unique identifier for the request
- `model` (string) - OpenAI model to use
- `endpoint` (string) - One of: `/v1/responses`, `/v1/embeddings`, `/v1/moderations`
- `input` - Input data (format varies by endpoint)
- `delivery` (object) - Delivery configuration

### Delivery Configuration

The `delivery` object specifies how to receive results:

**Webhook Delivery:**
```json
{
  "type": "webhook",
  "webhook_url": "https://example.com/webhook"
}
```

**RabbitMQ Delivery:**
```json
{
  "type": "rabbitmq",
  "rabbitmq_queue": "results_queue"
}
```

---

## 1. /v1/responses - Chat Completions

For generating text responses using chat models.

### Required Fields
- `custom_id`, `model`, `endpoint`, `input`, `delivery`

### Optional Fields
- `instructions` (string) - System instructions
- `temperature` (float 0-2) - Sampling temperature
- `max_output_tokens` (integer) - Maximum tokens in response
- `top_p` (float 0-1) - Nucleus sampling parameter
- `store` (boolean) - Store response for retrieval (default: true)

### Example 1: Simple Text Input

```json
{
  "data": {
    "type": "prompt",
    "attributes": {
      "request_body": {
        "custom_id": "req-001",
        "model": "gpt-4o",
        "endpoint": "/v1/responses",
        "input": "Explain quantum computing in simple terms",
        "delivery": {
          "type": "webhook",
          "webhook_url": "https://api.example.com/results"
        },
        "temperature": 0.7,
        "max_output_tokens": 500
      }
    }
  }
}
```

### Example 2: Conversation Messages

```json
{
  "data": {
    "type": "prompt",
    "attributes": {
      "request_body": {
        "custom_id": "conv-001",
        "model": "gpt-4o",
        "endpoint": "/v1/responses",
        "input": [
          {
            "role": "developer",
            "content": "You are a helpful coding assistant"
          },
          {
            "role": "user",
            "content": "Write a Python function to reverse a string"
          }
        ],
        "delivery": {
          "type": "rabbitmq",
          "rabbitmq_queue": "chat_responses"
        },
        "instructions": "Provide clear, commented code"
      }
    }
  }
}
```

---

## 2. /v1/embeddings - Text Embeddings

For generating vector embeddings from text.

### Required Fields
- `custom_id`, `model`, `endpoint`, `input`, `delivery`

### Optional Fields
- `dimensions` (integer) - Number of dimensions (text-embedding-3 models only)
- `encoding_format` (string) - Either `"float"` or `"base64"`

### Example 1: Single Text

```json
{
  "data": {
    "type": "prompt",
    "attributes": {
      "request_body": {
        "custom_id": "emb-001",
        "model": "text-embedding-3-large",
        "endpoint": "/v1/embeddings",
        "input": "The quick brown fox jumps over the lazy dog",
        "delivery": {
          "type": "webhook",
          "webhook_url": "https://api.example.com/embeddings"
        },
        "dimensions": 1536
      }
    }
  }
}
```

### Example 2: Multiple Texts (Batch)

```json
{
  "data": {
    "type": "prompt",
    "attributes": {
      "request_body": {
        "custom_id": "emb-batch-001",
        "model": "text-embedding-3-small",
        "endpoint": "/v1/embeddings",
        "input": [
          "First document to embed",
          "Second document to embed",
          "Third document to embed"
        ],
        "delivery": {
          "type": "rabbitmq",
          "rabbitmq_queue": "embedding_results"
        },
        "encoding_format": "float"
      }
    }
  }
}
```

---

## 3. /v1/moderations - Content Moderation

For checking content for policy violations.

### Required Fields
- `custom_id`, `model`, `endpoint`, `input`, `delivery`

### No Optional Fields

### Example 1: Single Text

```json
{
  "data": {
    "type": "prompt",
    "attributes": {
      "request_body": {
        "custom_id": "mod-001",
        "model": "omni-moderation-latest",
        "endpoint": "/v1/moderations",
        "input": "This is some user-generated content to check",
        "delivery": {
          "type": "webhook",
          "webhook_url": "https://api.example.com/moderation-results"
        }
      }
    }
  }
}
```

### Example 2: Multiple Texts

```json
{
  "data": {
    "type": "prompt",
    "attributes": {
      "request_body": {
        "custom_id": "mod-batch-001",
        "model": "text-moderation-latest",
        "endpoint": "/v1/moderations",
        "input": [
          "First comment to moderate",
          "Second comment to moderate",
          "Third comment to moderate"
        ],
        "delivery": {
          "type": "rabbitmq",
          "rabbitmq_queue": "moderation_queue"
        }
      }
    }
  }
}
```

---

## cURL Examples

### Responses Request

```bash
curl -X POST http://localhost:4000/api/json/prompt \
  -H "Content-Type: application/vnd.api+json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "data": {
      "type": "prompt",
      "attributes": {
        "request_body": {
          "custom_id": "curl-test-001",
          "model": "gpt-4o",
          "endpoint": "/v1/responses",
          "input": "Hello, world!",
          "delivery": {
            "type": "webhook",
            "webhook_url": "https://webhook.site/your-unique-url"
          }
        }
      }
    }
  }'
```

### Embeddings Request

```bash
curl -X POST http://localhost:4000/api/json/prompt \
  -H "Content-Type: application/vnd.api+json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "data": {
      "type": "prompt",
      "attributes": {
        "request_body": {
          "custom_id": "curl-emb-001",
          "model": "text-embedding-3-large",
          "endpoint": "/v1/embeddings",
          "input": ["Sample text to embed"],
          "delivery": {
            "type": "webhook",
            "webhook_url": "https://webhook.site/your-unique-url"
          }
        }
      }
    }
  }'
```

### Moderation Request

```bash
curl -X POST http://localhost:4000/api/json/prompt \
  -H "Content-Type: application/vnd.api+json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "data": {
      "type": "prompt",
      "attributes": {
        "request_body": {
          "custom_id": "curl-mod-001",
          "model": "omni-moderation-latest",
          "endpoint": "/v1/moderations",
          "input": "Content to moderate",
          "delivery": {
            "type": "webhook",
            "webhook_url": "https://webhook.site/your-unique-url"
          }
        }
      }
    }
  }'
```

---

## Response Format

All successful requests return a `201 Created` status with the created prompt resource:

```json
{
  "data": {
    "type": "prompt",
    "id": "123",
    "attributes": {
      "custom_id": "req-001",
      "model": "gpt-4o",
      "endpoint": "/v1/responses",
      "state": "pending",
      "batch_id": 45,
      "delivery_type": "webhook",
      "webhook_url": "https://api.example.com/results",
      "request_payload": {
        "model": "gpt-4o",
        "input": "..."
      }
    }
  }
}
```

---

## Error Responses

### Missing Required Fields

```json
{
  "errors": [
    {
      "code": "required",
      "title": "is required",
      "detail": "custom_id is required",
      "source": {
        "pointer": "/data/attributes/request_body/custom_id"
      }
    }
  ]
}
```

### Invalid Endpoint

```json
{
  "errors": [
    {
      "code": "invalid",
      "title": "is invalid",
      "detail": "endpoint must be '/v1/responses' for this request type",
      "source": {
        "pointer": "/data/attributes/request_body/endpoint"
      }
    }
  ]
}
```

### Invalid Delivery Configuration

```json
{
  "errors": [
    {
      "code": "invalid",
      "title": "is invalid",
      "detail": "webhook_url is required when delivery type is webhook",
      "source": {
        "pointer": "/data/attributes/request_body/delivery/webhook_url"
      }
    }
  ]
}
```

---

## Generating OpenAPI Spec

To generate the OpenAPI specification with proper `anyOf` schemas:

```bash
./generate_openapi.sh
```

Or manually:

```bash
mix openapi.spec.json --spec BatcherWeb.AshJsonApiRouter
mix openapi.fix_union
```

This will create `openapi.json` with proper discriminated union types showing all three request body schemas.

---

## Testing

View interactive API documentation at: `http://localhost:4000/api/json/swaggerui`

Access the OpenAPI spec at: `http://localhost:4000/api/json/open_api`

**Note**: The live OpenAPI endpoint serves the auto-generated spec. For the best documentation with proper `anyOf` schemas, use the generated `openapi.json` file after running `./generate_openapi.sh`.
