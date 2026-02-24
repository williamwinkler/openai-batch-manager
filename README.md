# OpenAI Batch Manager

OpenAI Batch Manager is a self-hosted service that turns the [OpenAI Batch API](https://developers.openai.com/api/docs/guides/batch/) into a simple workflow:
send requests now, receive results later (via webhook or RabbitMQ).

It includes an interactive UI at [http://localhost:4000](http://localhost:4000).

![ui](/docs/ui.png)

## Quickstart (Docker Compose)

This repo includes a `docker-compose.yml` that runs Postgres + OpenAI Batch Manager.

```bash
cp .env.example .env
# edit .env and set OPENAI_API_KEY
docker compose up -d --build
```

`docker compose` auto-loads `.env` automatically, so `source .env` is not required.
`docker-compose.yml` provisions Postgres and sets a default internal `DATABASE_URL`.
If you are using an external Postgres instance, set `DATABASE_URL` in `.env`.

Then open:

- UI: [http://localhost:4000](http://localhost:4000)
- Health check: [http://localhost:4000/health](http://localhost:4000/health)
- OpenAPI JSON: [http://localhost:4000/api/openapi](http://localhost:4000/api/openapi)
- Swagger UI: [http://localhost:4000/api/swaggerui](http://localhost:4000/api/swaggerui)

Optional: enable RabbitMQ intake/delivery

1. In `docker-compose.yml`, uncomment the `rabbitmq` service and the `RABBITMQ_*` env var lines under `openai-batch-manager`.
2. Set:

```env
RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672
RABBITMQ_INPUT_QUEUE=batch_requests
```

## Send a Request

Submit requests to the service, and it will batch/upload/poll/download and deliver results.
`custom_id` must be globally unique across all requests.

Webhook delivery:

```bash
curl -sS -X POST http://localhost:4000/api/requests \
  -H 'content-type: application/json' \
  -d '{
    "custom_id": "example_webhook_001",
    "url": "/v1/responses",
    "method": "POST",
    "body": {
      "model": "gpt-4o-mini",
      "input": "Return a JSON object with a single key: answer"
    },
    "delivery_config": {
      "type": "webhook",
      "webhook_url": "https://example.com/webhook"
    }
  }'
```

RabbitMQ delivery (queue-only):

```bash
curl -sS -X POST http://localhost:4000/api/requests \
  -H 'content-type: application/json' \
  -d '{
    "custom_id": "example_rabbitmq_001",
    "url": "/v1/responses",
    "method": "POST",
    "body": {
      "model": "gpt-4o-mini",
      "input": "Write a one sentence summary of: OpenAI Batch Manager"
    },
    "delivery_config": {
      "type": "rabbitmq",
      "rabbitmq_queue": "batch_results"
    }
  }'
```

## Why Use This?

The OpenAI Batch API is powerful, but it turns a single request into a workflow:
build the batch file, upload, poll status, handle partial failures/expired batches, download outputs, and deliver results.

OpenAI Batch Manager abstracts that workflow away. You get:

- A single intake API (`POST /api/requests`) with OpenAPI docs.
- Automatic batch creation + upload + status polling + result download.
- Delivery attempts with audit trail in the UI.
- Automatic cleanup of completed/expired/stale batches.

## How It Works

1. **Submit** requests (via REST API, optionally via RabbitMQ intake queue).
2. **Batch** by model/endpoint and persist locally.
3. **Upload** to OpenAI Batch API (by default, within about an hour).
4. **Poll** until OpenAI finishes processing.
5. **Download** output/error files and parse per-request results.
6. **Deliver** each result to your destination (webhook or RabbitMQ).

![diagram](/docs/how_it_works_diagram.png)

## Configuration

| Variable | Required | Purpose |
|----------|:--------:|---------|
| `OPENAI_API_KEY` | Yes | OpenAI API key used to create and poll batches. |
| `DATABASE_URL` | Yes | Postgres connection string (Ecto format). |
| `PORT` | No | HTTP port (default: `4000`). |
| `RABBITMQ_URL` | No | Enables RabbitMQ output delivery, and input consumption if `RABBITMQ_INPUT_QUEUE` is set. |
| `RABBITMQ_INPUT_QUEUE` | No | Enables RabbitMQ intake from this queue name (requires `RABBITMQ_URL`). |
| `DISABLE_DELIVERY_RETRY` | No | When true, delivery attempts are not retried. |

## Operational Notes

- Data artifacts live under `/data/batches` in the container. Postgres stores metadata (batches, requests, delivery attempts).
- Batches and their requests are automatically cleaned up:
  - **Completed batches** are deleted locally once their OpenAI file expires (30 days after upload).
  - **Stale building batches** that have been idle for over 1 hour are either uploaded (if they contain requests) or deleted (if empty).
  - **Expired OpenAI batches** (24h processing timeout) have their partial results downloaded and unprocessed requests resubmitted in a new batch.

When a batch is deleted locally, its associated OpenAI files (input, output, error) are also cleaned up on the OpenAI platform.

## Limitations / Not Supported

- No built-in authentication/authorization. Run behind a reverse proxy, VPN, or private network.
- Not a low-latency API and not a streaming API; this is for asynchronous batch workloads.
- Delivery should be treated as at-least-once; make your webhook/RabbitMQ consumers idempotent.
- RabbitMQ delivery is queue-only (`rabbitmq_queue`); custom exchanges/routing keys are not supported (yet).
- Only OpenAI Batch API workflows are in scope (not a multi-provider LLM router).

## Development (From Source)

You need Elixir/Erlang (e.g. [asdf](https://asdf-vm.com/) with `.tool-versions`), Postgres, and an OpenAI API key.
For `mix` development, this app reads `DATABASE_URL_DEV` from `config/dev.exs` (not `DATABASE_URL`).

```bash
cp .env.example .env
# edit .env and set OPENAI_API_KEY

# optional: if your local Postgres is not the default
export DATABASE_URL_DEV="ecto://postgres:postgres@localhost:5432/openai_batch_manager_dev"

asdf install
mix setup
iex -S mix phx.server
```

If you keep the default local Postgres settings, you can skip `DATABASE_URL_DEV`.

## Development Commands

```bash
mix test
mix format
mix precommit
```

To run RabbitMQ tests locally, run `mix test --include rabbitmq` with a RabbitMQ instance available.

## Contributing

Open an issue for bugs or ideas. PRs welcome—keep changes focused, add tests where relevant, run `mix precommit` before submitting.

Current baseline:

1. `mix precommit` is the required local/CI quality gate before merging.
2. `mix format --check-formatted` must pass.
3. No committed tooling/noise artifacts (for example `.DS_Store` and local logs).
4. Keep `Ash.*` orchestration out of web modules (`lib/batcher_web`) unless explicitly justified.

## License

[MIT](LICENSE) — use, modify, and redistribute; keep the license and copyright notice in redistributed code.
