# OpenAI Batch Manager

OpenAI Batch Manager is a self-hosted application that turns the [OpenAI Batch API](https://developers.openai.com/api/docs/guides/batch/) into a single intake workflow:
submit requests now, then receive results later by webhook or RabbitMQ.

## What This Project Does

OpenAIs [Batch API](https://developers.openai.com/api/docs/guides/batch/) offers lower cost and higher throughput of requests, which is great but using it effectively is a multi-step operational workflow:
build a batch file, upload it, poll for completion, handle partial failures or expired batches, download results, and deliver each result where it's needed.

OpenAI Batch Manager abstracts this complicated workflow away and offers:

- A single intake API: `POST /api/requests` (or through RabbitMQ)
- Automatic upload, polling, download, retry, and cleanup behavior
- Delivery to webhooks or RabbitMQ queues
- An interactive UI for managing batches, requests, and delivery attempts

## Who It Is For

This project is useful if you:

- Want lower OpenAI API costs
- Need asynchronous, high-volume OpenAI request processing
- Want auditability around request state and delivery state

> `No built-in authentication or authorization is included.` Run it behind a reverse proxy, VPN, private network or simply have it connect to an RabbitMQ instance for intake and delivery.

## Architecture Overview

At a high level, the application looks like this:

1. Accept requests via REST and, optionally, RabbitMQ intake.
2. Persist requests locally and group them into OpenAI-compatible batches.
3. Upload batch files to OpenAI on a scheduled cadence.
4. Poll OpenAI until each batch completes, expires, or fails.
5. Download output and error files, then map each result back to the original request.
6. Deliver results to a webhook or RabbitMQ queue with retry and audit history.

![diagram](/docs/how_it_works_diagram.png)

## Tech Stack

- Phoenix 1.8 + LiveView for the UI and HTTP layer
- Ash Framework for domain modeling and actions
- Oban for background jobs and orchestration
- Postgres for durable metadata
- OpenApiSpex for OpenAPI docs and request validation
- RabbitMQ for optional intake and delivery integration

## UI

The application includes an operator UI for inspecting batches, request state, and delivery attempts.

![ui](/docs/ui.png)

## Quickstart (Docker Compose)

The checked-in `docker-compose.yml` runs the application container only. You need an accessible Postgres instance, and optionally RabbitMQ, outside that compose file.

```bash
cp .env.example .env
# edit .env and set OPENAI_API_KEY
# set DATABASE_URL if your Postgres is not on localhost:5432
docker compose up -d --build
```

`docker compose` auto-loads `.env`, so `source .env` is not required.

By default, the container exposes port `4001`, not `4000`.

Then open:

- UI: [http://localhost:4001](http://localhost:4001)
- Health check: [http://localhost:4001/health](http://localhost:4001/health)
- OpenAPI JSON: [http://localhost:4001/api/openapi](http://localhost:4001/api/openapi)
- Swagger UI: [http://localhost:4001/api/swaggerui](http://localhost:4001/api/swaggerui)

### Docker Notes

- `DATABASE_URL` defaults to `ecto://postgres:postgres@localhost:5432/openai_batch_manager` for local `mix` development via `.env.example`.
- Inside Docker Compose, the app container uses `DATABASE_URL_DOCKER` if set, otherwise it falls back to `ecto://postgres:postgres@host.docker.internal:5432/openai_batch_manager`.
- If you are on Linux and `host.docker.internal` is unavailable, set `DATABASE_URL_DOCKER` explicitly in `.env`.

## Send a Request

Submit requests to the service and it will batch, upload, poll, download, and deliver results.
`custom_id` must be globally unique across all requests.

Webhook delivery:

```bash
curl -sS -X POST http://localhost:4001/api/requests \
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

RabbitMQ delivery:

```bash
curl -sS -X POST http://localhost:4001/api/requests \
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

## Verify It Is Working

After creating a request, you can inspect it through the API or UI.

Look up a request by `custom_id`:

```bash
curl -sS http://localhost:4001/api/requests/example_webhook_001
```

Useful places to verify behavior:

- `/requests` in the UI for request state and delivery history
- `/batches` in the UI for grouped OpenAI batch activity
- `/api/swaggerui` for the request schema and response models
- `/health` for a simple container health check

## RabbitMQ Queue Provisioning

RabbitMQ queue provisioning is your responsibility.
The manager only consumes from and publishes to existing queues.

- `RABBITMQ_INPUT_QUEUE` must already exist before intake can work.
- `delivery_config.rabbitmq_queue` must already exist before RabbitMQ delivery can succeed.
- The app does not auto-declare or auto-create queues at startup or at delivery time.

Typical RabbitMQ setup:

```env
RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672
RABBITMQ_INPUT_QUEUE=batch_requests
```

## Configuration

| Variable | Required | Purpose |
|----------|:--------:|---------|
| `OPENAI_API_KEY` | Yes | OpenAI API key used to create and poll batches. |
| `DATABASE_URL` | Yes for production | Postgres connection string used by the app process. |
| `DATABASE_URL_DOCKER` | No | Docker-only override for the containerized app connection string. |
| `PORT` | No | HTTP port. Defaults to `4000` in app config, `4001` in `docker-compose.yml`. |
| `RABBITMQ_URL` | No | Enables RabbitMQ output delivery, and input consumption if `RABBITMQ_INPUT_QUEUE` is set. |
| `RABBITMQ_INPUT_QUEUE` | No | Enables RabbitMQ intake from this queue name. |
| `SECRET_KEY_BASE` | No | Recommended for persistent production deployments; auto-generated if omitted. |

## Project Layout

For contributors, the repo is organized around a small set of responsibilities:

- `lib/batcher/batching` contains the core domain: batches, requests, transitions, delivery attempts, actions, changes, and workflow logic.
- `lib/batcher/clients/openai` contains the OpenAI-facing client code.
- `lib/batcher/rabbitmq` contains the optional intake and delivery integration.
- `lib/batcher/open_api` and `lib/batcher_web/schemas` define the OpenAPI spec and request/response schemas.
- `lib/batcher_web/live` contains the operator UI.
- `lib/batcher_web/controllers` exposes the REST endpoints and file download routes.
- `config/` contains runtime and environment-specific configuration, including `.env` loading in `config/runtime.exs`.
- `test/` covers domain behavior, API interactions, and integration edges.

If you are trying to understand the product quickly, start with:

1. `lib/batcher/batching/batch.ex`
2. `lib/batcher/batching/request.ex`
3. `lib/batcher/batching/actions/`
4. `lib/batcher_web/router.ex`
5. `lib/batcher_web/controllers/request_controller.ex`

## Operational Notes

- Data artifacts live under `/data/batches` in the container, or `tmp/batches` in local development.
- Postgres stores metadata such as batches, requests, transitions, and delivery attempts.
- Completed batches are deleted locally once their OpenAI files expire.
- Stale building batches that sit idle for over 1 hour are either uploaded or deleted, depending on whether they contain requests.
- Expired OpenAI batches have partial results processed and remaining requests resubmitted in a new batch.

When a batch is deleted locally, its associated OpenAI files are also cleaned up on the OpenAI platform.

Delivery defaults are tuned to avoid bursty Postgres lock pressure:

- Delivery worker concurrency is fixed at `8`.
- Delivery enqueue fanout is fixed at `200` requests.
- Repetitive enqueue failures are summarized with up to `5` warning logs.

For very large batches, RabbitMQ delivery is strongly recommended.
Webhook endpoints can become the bottleneck at that scale and can increase timeouts or connection errors.

## Limitations

- Delivery should be treated as at-least-once. Webhook handlers and RabbitMQ consumers should be idempotent.
- RabbitMQ delivery is queue-only. Custom exchanges and routing keys are not currently supported.
- The system is intentionally asynchronous. It is not designed for request-response latency.

## Development

You need Elixir/Erlang, Postgres, and an OpenAI API key.
Using [asdf](https://asdf-vm.com/) with [`.tool-versions`](.tool-versions) is the easiest local setup path.

For local `mix` development, the app reads `.env` via `config/runtime.exs`.

```bash
cp .env.example .env
asdf install
mix setup
iex -S mix phx.server
```

If you keep the default local Postgres settings from `.env.example`, you can usually run without changing `DATABASE_URL`.

Local development uses port `4000` by default.

## Development Commands

```bash
mix test
mix format
mix precommit
```

To run RabbitMQ tests locally, run `mix test --include rabbitmq` with a RabbitMQ instance available.

## Contributing

Open an issue for bugs or ideas. PRs are welcome.

Contributor baseline:

1. Keep changes focused.
2. Add or update tests where behavior changes.
3. Run `mix precommit` before submitting.
4. Avoid pushing Ash orchestration into `lib/batcher_web` unless there is a clear reason.
5. Do not commit local tooling noise such as `.DS_Store` or logs.

## License

[MIT](LICENSE) — use, modify, and redistribute under the terms of the included license.
