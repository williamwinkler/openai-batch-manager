# SQLite Configuration Guide

This document explains the SQLite optimizations applied across all environments in this project.

## Why These Optimizations Matter

SQLite is file-based and has different concurrency characteristics than client-server databases like PostgreSQL. Without proper configuration, you'll encounter:
- "Database busy" errors
- Poor performance under concurrent load
- Timeouts during web requests + background jobs

## Configuration by Environment

### Test Environment ([config/test.exs](config/test.exs))

```elixir
config :batcher, Batcher.Repo,
  database: Path.expand("../batcher_test.db", __DIR__),
  pool_size: 10,
  pool: Ecto.Adapters.SQL.Sandbox,
  timeout: 60_000,
  after_connect: {Exqlite.Sqlite3, :execute,
    ["PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"]}
```

**Purpose:** Handle concurrent async tests without "Database busy" errors

**Key settings:**
- **WAL mode** - Allows readers/writers to work concurrently
- **5s busy timeout** - Retries for 5 seconds instead of failing immediately
- **Pool size: 10** - Enough connections for concurrent tests

### Development Environment ([config/dev.exs](config/dev.exs))

```elixir
config :batcher, Batcher.Repo,
  database: Path.expand("../batcher_dev.db", __DIR__),
  pool_size: 10,
  timeout: 60_000,
  after_connect: {Exqlite.Sqlite3, :execute,
    ["PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"]}
```

**Purpose:** Smooth development experience with LiveView, web requests, and Oban jobs running concurrently

**Benefits:**
- No "Database busy" errors when clicking around the UI
- Oban jobs can run while you're using the app
- Better performance with multiple browser tabs

### Production Environment ([config/runtime.exs](config/runtime.exs))

```elixir
config :batcher, Batcher.Repo,
  database: database_path,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  timeout: 60_000,
  queue_target: 5_000,
  queue_interval: 1_000,
  after_connect:
    {Exqlite.Sqlite3, :execute,
     [
       """
       PRAGMA journal_mode=WAL;
       PRAGMA busy_timeout=5000;
       PRAGMA synchronous=NORMAL;
       PRAGMA cache_size=-64000;
       PRAGMA temp_store=memory;
       PRAGMA mmap_size=30000000000;
       """
     ]}
```

**Purpose:** Maximum performance and reliability under production load

## PRAGMA Explanations

### Essential (All Environments)

#### `PRAGMA journal_mode=WAL`
**What it does:** Enables Write-Ahead Logging

**Why:**
- Default mode blocks readers during writes and vice versa
- WAL allows concurrent readers and one writer
- **Critical for web apps** with simultaneous users + background jobs

**Trade-off:** Creates `-wal` and `-shm` files alongside the main `.db` file

#### `PRAGMA busy_timeout=5000`
**What it does:** Wait up to 5 seconds when database is locked

**Why:**
- Default is 0ms - immediate failure
- 5 seconds gives time for other transactions to complete
- Prevents "Database busy" errors under normal load

**When to increase:** If you have long-running transactions or high concurrency

### Production-Only Optimizations

#### `PRAGMA synchronous=NORMAL`
**What it does:** Relaxes durability guarantees slightly

**Default:** FULL (fsync after every write)
**NORMAL:** fsync only at critical moments (checkpoints)

**Why:**
- 2-3x faster writes
- Still safe for most crashes (only vulnerable during OS crashes during checkpoint)
- With WAL mode, this is the recommended setting

**Trade-off:** Very small risk of corruption if OS crashes at exact wrong moment

#### `PRAGMA cache_size=-64000`
**What it does:** Use 64MB of RAM for caching pages

**Default:** ~2MB
**Value:** Negative number means kilobytes (64000 KB = 64 MB)

**Why:**
- More cache = fewer disk reads
- Significantly improves query performance
- Modern servers have RAM to spare

**Adjust:** Increase for larger databases or more available RAM

#### `PRAGMA temp_store=memory`
**What it does:** Keep temporary tables and indices in RAM

**Default:** FILE (uses disk)

**Why:**
- Faster temporary operations (sorts, temp tables)
- Reduces disk I/O

**Trade-off:** Uses more RAM (usually negligible)

#### `PRAGMA mmap_size=30000000000`
**What it does:** Memory-map up to 30GB of the database file

**Default:** 0 (disabled)

**Why:**
- OS handles caching instead of SQLite
- Can be much faster for read-heavy workloads
- Reduces system calls

**Trade-off:**
- Uses virtual address space (not actual RAM)
- On 32-bit systems, keep this lower or disabled

## When to Use PostgreSQL Instead

SQLite is excellent for:
- ✅ Small to medium apps (< 100 concurrent users)
- ✅ Read-heavy workloads
- ✅ Single-server deployments
- ✅ Applications where simplicity matters

Consider PostgreSQL when:
- ❌ High concurrent write load (> 100 writes/sec sustained)
- ❌ Multi-server deployments (need shared database)
- ❌ Very large databases (> 100GB)
- ❌ Complex analytics queries

## Monitoring & Tuning

### Check if WAL mode is enabled:
```bash
sqlite3 batcher_dev.db "PRAGMA journal_mode;"
# Should output: wal
```

### View current PRAGMAs:
```bash
sqlite3 batcher_dev.db <<EOF
PRAGMA journal_mode;
PRAGMA synchronous;
PRAGMA cache_size;
PRAGMA mmap_size;
EOF
```

### Performance Issues?

1. **Still seeing "Database busy"?**
   - Increase `busy_timeout` to 10000 (10 seconds)
   - Check for long-running transactions
   - Consider increasing pool size

2. **Slow queries?**
   - Increase `cache_size` (more RAM)
   - Add database indexes
   - Use `EXPLAIN QUERY PLAN` to analyze queries

3. **High memory usage?**
   - Decrease `cache_size`
   - Decrease `mmap_size`
   - Check for memory leaks in your code

## WAL Mode Housekeeping

WAL mode creates extra files:
- `batcher.db` - Main database
- `batcher.db-wal` - Write-ahead log
- `batcher.db-shm` - Shared memory index

**Important:**
- Never delete WAL/SHM files while app is running
- Backup all three files together
- WAL auto-checkpoints periodically (merges changes back)

## Environment Variables

Production accepts these env vars:

```bash
# Database location (required)
DATABASE_PATH=/var/lib/batcher/batcher.db

# Connection pool size (optional, default: 10)
POOL_SIZE=20  # Increase for high concurrency
```

## Additional Resources

- [SQLite WAL Mode](https://www.sqlite.org/wal.html)
- [SQLite Performance Tuning](https://www.sqlite.org/pragma.html)
- [When to use SQLite](https://www.sqlite.org/whentouse.html)
