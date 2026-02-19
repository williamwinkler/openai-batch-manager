# OpenAI Batch Manager

OpenAI Batch Manager helps you reduce OpenAI API costs for non-urgent workloads with a simple “send request, get result later” workflow using the [Batch API](https://platform.openai.com/docs/guides/batch).

## How it works

1. **Submit** — Your program sends requests (e.g. via API or RabbitMQ).
2. **Batch** — The app groups them by model/endpoint and stores them locally.
3. **Upload** — Within an hour, it uploads the batch to OpenAI’s platform.
4. **Poll** — It periodically checks batch status on OpenAI until processing finishes.
5. **Download** — When done, it fetches the result file and parses per-request outputs.
6. **Deliver** — Each result is sent back to your program (webhook or RabbitMQ).

![diagram](/docs/how_it_works_diagram.png)

It comes with an [interactive UI](http://localhost:4000), where you can manage your batches, requests and delivery attempts.

![ui](/docs/ui.png)

## Why use this project?

Sending large volumes of requests to OpenAI’s models can get expensive. For high-throughput workloads, OpenAI offers the [Batch API](https://platform.openai.com/docs/guides/batch), which can reduce cost and lets OpenAI process requests asynchronously in the background, often improving throughput by scheduling work when capacity is available.

The Batch API is useful, but it turns “make a request” into a workflow: you have to package inputs, upload batches, poll for status, handle partial failures/expired batches, download outputs, and reconcile results back to the original requests.

OpenAI Batch Manager abstracts this away for you.

You just send it requests, choose how you want results delivered, and it takes care of the batch creation, tracking, retries, resubmission of expired batches, and returning the final output reliably.

## How to use

A build [docker image](https://hub.docker.com/r/williamwinkler/openai-batch-manager) is already available. Simple start it with Docker:

```bash
docker run -d --name openai-batch-manager \
  -p 4000:4000 \
  -e OPENAI_API_KEY="sk-your-key-here" \
  -v openai-batch-manager-data:/data \
  williamwinkler/openai-batch-manager:latest
```
> The named volume stores the SQLite database and batch files persistently.

Or with Docker Compose — save as `docker-compose.yml`:

```yaml
services:
  openai-batch-manager:
    image: williamwinkler/openai-batch-manager:latest
    ports:
      - "4000:4000"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - RABBITMQ_URL=${RABBITMQ_URL}                  # Optional
      - RABBITMQ_INPUT_QUEUE=${RABBITMQ_INPUT_QUEUE}  # Optional
    volumes:
      - openai-batch-manager-data:/data
    logging: # Optional
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "3"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  rabbitmq: # Optional - or use an existing instance
    image: rabbitmq:4-management
    ports:
      - "5672:5672"
      - "15672:15672"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  openai-batch-manager-data:
```

Then set environment variables (e.g. in a `.env` file) and run:

```shell
docker compose up -d
```

### Why use a named Docker volume for `/data`?

`/data` contains the SQLite database and batch files. It's recommended to use a **named Docker volume** instead of a host bind mount because it usually performs better for SQLite-heavy write workloads.

- On **macOS** (and often **Windows** with Docker Desktop), bind-mounted filesystem I/O can be significantly slower, which can hurt write throughput.
- On **Linux**, bind mounts are typically faster than on Docker Desktop, but named volumes are still a solid default for database performance and portability.

If you need host-visible artifacts, bind-mount only those specific paths (for example `./exports:/exports`) and keep `/data` on a named volume.

### Database export and reset from UI

When using named volumes, the SQLite file is not directly visible in your project folder.

- Open **`/settings`** and use **Download DB Snapshot** to export a consistent `.db` backup file.
- Use **Erase DB** (typed confirmation required) to reset local data to a clean slate.

### RabbitMQ configuration

RabbitMQ is **optional**. The app can ingest requests via the REST API only, or add RabbitMQ for queue-based intake and/or result delivery.

| Variable | Purpose |
|----------|---------|
| `RABBITMQ_URL` | Connection string (e.g. `amqp://user:pass@host:5672`). When set, the app can **publish** completed results to RabbitMQ (per-request delivery to queues you configure). |
| `RABBITMQ_INPUT_QUEUE` | Queue name. When set together with `RABBITMQ_URL`, the app **consumes** batch requests from this queue (alternative to sending requests via REST). |
| `RABBITMQ_INPUT_EXCHANGE` | (Optional) Consume from an exchange instead of a queue. If set, `RABBITMQ_INPUT_ROUTING_KEY` must also be set. |
| `RABBITMQ_INPUT_ROUTING_KEY` | (Optional) Routing key when using `RABBITMQ_INPUT_EXCHANGE`. |

- **Output delivery:** With `RABBITMQ_URL` set, each completed request can be published to a RabbitMQ queue (you specify the queue when creating the request). Useful for feeding results into other services.
- **Input:** With both `RABBITMQ_URL` and `RABBITMQ_INPUT_QUEUE` set, the app subscribes to that queue and creates batch requests from messages it receives, so producers can push work via RabbitMQ instead of (or in addition to) the REST API.

### API Documentation

The app serves an OpenAPI specification and interactive Swagger UI:

- **OpenAPI spec (JSON):** http://localhost:4000/api/openapi
- **Swagger UI:** http://localhost:4000/api/swaggerui

You can use the spec to generate typed API clients. For example:

**TypeScript:**
```bash
npx @openapitools/openapi-generator-cli generate \
  -i http://localhost:4000/api/openapi \
  -g typescript-fetch \
  -o ./generated/typescript-client
```

**Python:**
```bash
npx @openapitools/openapi-generator-cli generate \
  -i http://localhost:4000/api/openapi \
  -g python \
  -o ./generated/python-client
```

### Data retention

Batches and their requests are automatically cleaned up:

- **Completed batches** are deleted locally once their OpenAI file expires (30 days after upload).
- **Stale building batches** that have been idle for over 1 hour are either uploaded (if they contain requests) or deleted (if empty).
- **Expired OpenAI batches** (24h processing timeout) have their partial results downloaded and unprocessed requests resubmitted in a new batch.

When a batch is deleted locally, its associated OpenAI files (input, output, error) are also cleaned up on the OpenAI platform.

## How to setup

**You need:** Elixir/Erlang (e.g. [asdf](https://asdf-vm.com/) with `.tool-versions`), SQLite, and an OpenAI API key.

```bash
asdf install && mix setup
export OPENAI_API_KEY="sk-..."
iex -S mix phx.server
```

Then you should see the frontedn at: **http://localhost:4000**

### Configuration

| Variable | Required | Default |
|----------|:--------:|--------|
| `OPENAI_API_KEY` | Yes | — |
| `PORT` | No | `4000` |
| `RABBITMQ_URL` | No | — |
| `RABBITMQ_INPUT_QUEUE` | No | — |
| `RABBITMQ_INPUT_EXCHANGE` | No | — |
| `RABBITMQ_INPUT_ROUTING_KEY` | No | — |
| `DISABLE_DELIVERY_RETRY` | No | `false` |

Data lives at `/data/batcher.db` and `/data/batches` (mount a volume at `/data` in Docker).

When `DISABLE_DELIVERY_RETRY=true` (also accepts `1`/`yes`), failed delivery attempts are **not retried** and each request gets only one delivery attempt.

### Capacity limits behavior

- Token estimation uses one canonical user-visible metric:
  - `estimated_request_input_tokens_total` (sum of per-request estimates)
  - Includes the default safety buffer (`request_safety_buffer`, default `1.10`)
- Admission/capacity checks use that same canonical metric, so the estimate shown in batch views matches queue-admission decisions.
- The app uses **Tier 1 default batch queue limits** for known models.
- If a model is not covered by Tier 1 defaults, the app uses a conservative unknown-model fallback limit.
- OpenAI's "TPD" value on the organization limits page behaves like a **max enqueued batch-token headroom** limit per model (tokens in active OpenAI states), not a strict 24-hour cumulative send cap. After earlier batches leave active queue usage, new batches can start the same day.

#### Backfill token estimates

After changing token-estimation settings, run:

```bash
mix batcher.backfill_request_token_estimates
```

This recomputes request-level token estimates and refreshes batch totals.

#### Queue token cap overrides in UI

- Open **`/settings`** to override queue token caps per model.
- Overrides use **prefix matching** (case-insensitive), with longest-prefix wins.
  - Example: overriding `gpt-4o` **does** affect `gpt-4o-mini-2024-07-18` unless a more specific prefix override exists.
- Limit resolution order is:
  1. Longest matching model-prefix override from `/settings`
  2. Built-in Tier 1 default for known model families
  3. Unknown-model fallback limit

## Development

```bash
mix test
mix format
mix precommit
```

OpenAI Batch Manager is a standalone [Phoenix](https://phoenixframework.org/) program that turns the OpenAI Batch API into a reliable pipeline: intake via REST (or RabbitMQ), batch aggregation per model/endpoint with GenServer, and background orchestration with Oban (upload → poll → download → deliver). The core domain uses [Ash Framework](https://ash-hq.org/) with SQLite persistence, and a LiveView UI (Tailwind + daisyUI) for visibility into batches and requests.

Use `mix ash.*` for migrations and codegen.

To run RabbitMQ tests, spin up a RabbitMQ instance and run `mix test --include rabbitmq`.

## Contributing Quality

This repository enforces a structured, reproducible audit standard for OSS-quality maintenance.

- Audit spec (source of truth): [`docs/audit_spec.md`](docs/audit_spec.md)
- Latest V2 audit report: [`docs/audits/2026-02-18_full_repo_audit.md`](docs/audits/2026-02-18_full_repo_audit.md)
- Latest findings data: [`docs/audits/2026-02-18_findings.json`](docs/audits/2026-02-18_findings.json)
- Latest full file matrix: [`docs/audits/2026-02-18_file_matrix.csv`](docs/audits/2026-02-18_file_matrix.csv)

Default quality gates:

1. No unresolved `P0/P1` findings in runtime-critical scope.
2. No direct `Ash.*` orchestration in web modules unless explicitly justified.
3. `mix format --check-formatted` must pass.
4. No committed tooling/noise artifacts (`.DS_Store`, editor logs, local caches).
5. Runtime docs policy in `lib/**`: `@moduledoc` and `@doc` coverage (with explicit allowlist for generated boilerplate).

## Contributing

Open an issue for bugs or ideas (repro steps and expected behavior). PRs welcome—keep changes focused, add tests where relevant, run `mix precommit` before submitting.

## License

[MIT](LICENSE) — use, modify, and redistribute; keep the license and copyright notice in redistributed code.
