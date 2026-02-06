# OpenAI Batch Manager

OpenAI Batch Manager helps you reduce OpenAI API costs for non-urgent workloads with a simple “send request, get result later” workflow using the [Batch API](https://platform.openai.com/docs/guides/batch).

## How it works

1. **Submit** — Your program sends requests (e.g. via API or RabbitMQ).
2. **Batch** — The app groups them by model/endpoint and stores them locally.
3. **Upload** — Within an hour, it uploads the batch to OpenAI’s platform.
4. **Poll** — It periodically checks batch status on OpenAI until processing finishes.
5. **Download** — When done, it fetches the result file and parses per-request outputs.
6. **Deliver** — Each result is sent back to your program (webhook or RabbitMQ).

It also includes an interactive UI, where you can manage your batches, requests and delivery attempts.

## Why use this project?


Sending large volumes of requests to OpenAI’s models can get expensive. For high-throughput workloads, OpenAI offers the [Batch API](https://platform.openai.com/docs/guides/batch), which can reduce cost and lets OpenAI process requests asynchronously in the background, often improving throughput by scheduling work when capacity is available.

The Batch API is useful, but it turns “make a request” into a workflow: you have to package inputs, upload batches, poll for status, handle partial failures/expired batches, download outputs, and reconcile results back to the original requests.

OpenAI Batch Manager abstracts this away for you.

You just send it requests, choose how you want results delivered, and it takes care of the batch creation, tracking, retries, resubmission of expired batches, and returning the final output reliably.

## How to use

Run this project with Docker:

```bash
docker run -d --name openai-batch-manager \
  -p 4000:4000 \
  -e OPENAI_API_KEY="sk-your-key-here" \
  -v "$(pwd)/data:/data" \
  williamwinkler/openai-batch-manager:latest
```
> The volume is the SQLite database, where it stores requests and responses (for 30 days).

Or with Docker Compose—save as `docker-compose.yml` (with RabbitMQ):

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
      - ./data:/data
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
```

Then set environment variables (e.g. in a `.env` file) and run:

```shell
docker compose up -d
```

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

Data lives at `/data/batcher.db` and `/data/batches` (mount a volume at `/data` in Docker).

## Development

```bash
mix test
mix format
mix precommit
```

OpenAI Batch Manager is a standalone [Phoenix](https://phoenixframework.org/) program that turns the OpenAI Batch API into a reliable pipeline: intake via REST (or RabbitMQ), batch aggregation per model/endpoint with GenServer, and background orchestration with Oban (upload → poll → download → deliver). The core domain uses [Ash Framework](https://ash-hq.org/) with SQLite persistence, and a LiveView UI (Tailwind + daisyUI) for visibility into batches and requests.

Use `mix ash.*` for migrations and codegen.

To run RabbitMQ tests, spin up a RabbitMQ instance and run `mix test --include rabbitmq`.

## Contributing

Open an issue for bugs or ideas (repro steps and expected behavior). PRs welcome—keep changes focused, add tests where relevant, run `mix precommit` before submitting.

## License

[MIT](LICENSE) — use, modify, and redistribute; keep the license and copyright notice in redistributed code.
