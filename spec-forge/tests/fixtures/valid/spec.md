# Spec — report generation cache

## §1 Goals

- Keep synchronous report generation and cut repeat latency with a cache.

## §2 Interfaces

- `GET /reports/{id}` — unchanged response body.
- `GET /reports/{id}?refresh=1` — bypass the cache.

## §3 Behavior

### §3.1 Cached read

1. A second request for the same report within 10 minutes is served from the cache.

### §3.2 Refresh

- `?refresh=1` regenerates the report and replaces the cached copy.

## §4 Constraints

- **Off-limits paths:** `legacy/` must not be modified.

## §5 Test criteria

### §5.1 Cache hit

- `python3 -m unittest tests.test_reports.CacheTest -v`

### §5.2 Refresh bypass

```bash
python3 -m unittest tests.test_reports.RefreshTest -v
```

## §6 Non-goals

- Background job processing (alternative B, rejected).
