# Docker Quick Start Guide

This guide shows you how to build and run the OpenAI Batch Manager using Docker.

## Prerequisites

- Docker installed and running
- OpenAI API key

## Build the Image

```bash
docker build -t openai-batch-manager:latest .
```

## Run the Container

### Minimal Setup (Just API Key + Volume)

```bash
# Create data directory
mkdir -p ./data

# Run the container (SECRET_KEY_BASE is auto-generated if not provided)
docker run -d \
  --name openai-batch-manager \
  -p 4000:4000 \
  -v $(pwd)/data:/data \
  -e OPENAI_API_KEY="sk-your-key-here" \
  openai-batch-manager:latest
```

**Note:** `SECRET_KEY_BASE` is optional and will be auto-generated if not set. This is fine for localhost use, but for production you may want to set it explicitly so it persists across restarts.

### Using Docker Compose

1. **Copy the example file:**
   ```bash
   cp docker-compose.example.yml docker-compose.yml
   ```

2. **Edit `docker-compose.yml`** and set:
   - `OPENAI_API_KEY`: Your OpenAI API key
   - `SECRET_KEY_BASE`: (Optional) Secret for signing cookies - auto-generated if not set

3. **Start the service:**
   ```bash
   docker-compose up -d
   ```

4. **View logs:**
   ```bash
   docker-compose logs -f
   ```

## Verify It's Running

```bash
# Check container status
docker ps

# Check health status
docker inspect openai-batch-manager | grep -A 5 Health

# Test the health endpoint
curl http://localhost:4000/health
# Should return: {"status":"ok"}

# Test the main app
curl http://localhost:4000/
```

## Access the Application

- **Main App**: http://localhost:4000
- **Oban Dashboard**: http://localhost:4000/oban (if dev_routes enabled)

## Data Persistence

All data is stored in the mounted volume at `./data`:
- Database: `./data/batcher.db`
- Batch files: `./data/batches/`

**Important**: Make sure to back up the `./data` directory regularly!

## Environment Variables

### Required

- `OPENAI_API_KEY`: Your OpenAI API key

### Optional (with defaults)

- `SECRET_KEY_BASE`: Secret for signing cookies (auto-generated if not set - fine for localhost use)

- `DATABASE_PATH`: Database file path (default: `/data/batcher.db`)
- `BATCH_STORAGE_PATH`: Batch files directory (default: `/data/batches`)
- `PORT`: HTTP port (default: `4000`)
- `PHX_HOST`: Hostname (default: `localhost`)
- `POOL_SIZE`: Database pool size (default: `1` - keep this for SQLite)

## Troubleshooting

### Container won't start

Check the logs:
```bash
docker logs openai-batch-manager
```

Common issues:
- Missing `OPENAI_API_KEY` or `SECRET_KEY_BASE`
- Port 4000 already in use (change with `-p 8080:4000`)
- Permission issues with data directory (ensure it's writable)

### Database errors

The database is created automatically on first run. If you see database errors:
1. Ensure the `/data` volume is mounted and writable
2. Check logs for specific error messages
3. Try removing the database file and restarting (data will be lost)

### Upgrading to a New Version

When you replace an old container with a new version:

1. **Pull/build the new image:**
   ```bash
   docker build -t openai-batch-manager:latest .
   # or
   docker pull openai-batch-manager:latest
   ```

2. **Stop and remove the old container:**
   ```bash
   docker stop openai-batch-manager
   docker rm openai-batch-manager
   ```

3. **Start the new container** (same command as before):
   ```bash
   docker run -d \
     --name openai-batch-manager \
     -p 4000:4000 \
     -v $(pwd)/data:/data \
     -e OPENAI_API_KEY="your-key" \
     -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
     openai-batch-manager:latest
   ```

4. **Migrations run automatically!** The new container will:
   - Detect any new migration files
   - Automatically run pending migrations
   - Skip migrations that have already been applied
   - Start the application normally

**Important:** Always keep your `/data` volume mounted - this preserves your database and ensures migrations can run against the existing database.

### Health check failing

The health check pings `http://localhost:4000/health`. If it fails:
- Check if the app is actually running: `docker logs openai-batch-manager`
- Verify the port mapping is correct
- The app might still be starting up (wait up to 60 seconds during initial startup)
- Test manually: `docker exec openai-batch-manager curl -f http://localhost:4000/health`

## Stopping and Cleaning Up

```bash
# Stop the container
docker stop openai-batch-manager

# Remove the container
docker rm openai-batch-manager

# Remove the image
docker rmi openai-batch-manager:latest

# Remove data (WARNING: This deletes your database!)
rm -rf ./data
```

## Production Deployment

For production, consider:

1. **Use a secrets manager** instead of environment variables
2. **Set up proper SSL/TLS** (reverse proxy like nginx, Traefik, or Caddy)
3. **Configure backups** for the `/data` directory
4. **Set resource limits** in docker-compose:
   ```yaml
   deploy:
     resources:
       limits:
         cpus: '2'
         memory: 2G
   ```
5. **Use a proper secret key** (not the example one)
6. **Set `PHX_HOST`** to your actual domain

## Image Details

The Docker image is optimized for production use:

- **Alpine Linux base**: Ultra-small footprint (~50MB final image)
- **Multi-stage build**: Separates build dependencies from runtime
- **Non-root user**: Runs as `appuser` (UID 1000) for security
- **Tini init**: Proper signal handling and zombie process reaping
- **Health check**: Built-in health endpoint at `/health` for orchestration
- **Volume support**: Persistent data directory at `/data`
- **OCI labels**: Standard metadata for image registries

### Build Arguments

You can customize the build with these arguments:

```bash
docker build \
  --build-arg ELIXIR_VERSION=1.18.2 \
  --build-arg OTP_VERSION=27.2.1 \
  --build-arg ALPINE_VERSION=3.21.2 \
  -t openai-batch-manager:latest .
```
