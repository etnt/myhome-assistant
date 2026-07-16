# Aircraft Identification Plan

## Overview

Add a manually initiated feature that identifies the aircraft most likely to be
flying over the configured home location. The ESP32-S3 queries the OpenSky REST
API once when requested, ranks nearby aircraft, and enriches the best candidate
with aircraft and route metadata from ADSBDB. HexDB can be used as an optional
fallback.

There is no periodic polling, background tracking, or flight-history storage.
The result is a best-effort identification based on public ADS-B data and must
not imply knowledge of passengers or crew.

## Goals

- Start identification only after an explicit HTTP or dashboard action.
- Find the aircraft with the highest apparent elevation above the home location.
- Return the ICAO24 address, callsign, position age, altitude, distance, bearing,
  track, speed, and estimated elevation angle.
- Enrich the result with registration, manufacturer, model, owner/operator,
  airline, origin, destination, and photograph when available.
- Report why no reliable candidate could be identified.
- Keep network failures isolated from the existing lighting and sensor services.
- Remain compatible with AtomVM on the ESP32-S3.

## Non-goals

- Continuous polling, alerts, or automatic aircraft tracking.
- Historical flight lookup or storage.
- Identification of passengers, crew, or the current occupant of a private
  aircraft.
- Guaranteed identification of military, privacy-filtered, non-ADS-B, or
  out-of-coverage aircraft.
- A general-purpose HTTP client beyond what this feature requires.

## Proposed User Experience

Add an **Identify aircraft overhead** card to the dashboard. The card is idle
until the user presses **Identify**.

During a request:

1. Disable the button and show `Checking nearby airspace...`.
2. Make one request to the device endpoint.
3. Display the best candidate, alternatives if the result is ambiguous, or a
   clear no-result/error state.
4. Re-enable the button. Do not schedule another request.

Example successful result:

```text
SAS SK1421 - high confidence
Airbus A320neo, SE-ROJ
Stockholm (ARN) -> Copenhagen (CPH)
10,600 m altitude, 2.1 km southwest, 78 degrees elevation
Position updated 6 seconds ago
```

The UI must label registry owner data as **Registered owner/operator**, since it
is not proof of who operates the current flight.

## Architecture

```text
Browser dashboard
    |
    | POST /api/aircraft/identify
    v
myhome_http_handler
    |
    | myhome_aircraft:identify/0, explicit 30 s call timeout
    v
myhome_aircraft (new supervised gen_server; no periodic timer)
    |
    +-- myhome_aircraft_geo (pure candidate filtering/ranking)
    |
    +-- myhome_rest_client (small wrapper around AtomVM ahttp_client)
          |
          +-- OpenSky /api/states/all (one bounded state query)
          |
          +-- ADSBDB aircraft + callsign lookup (best candidate only)
          |
          +-- HexDB lookup (optional fallback only)
```

`myhome_aircraft` serializes manual requests, keeps network work out of the HTTP
handler process, and optionally caches enrichment records by ICAO24 for the
current boot. It must not start timers or query providers from `init/1`.

## Phase 0: AtomVM Feasibility Gate

Before implementing feature logic, validate outbound HTTPS on the exact
firmware build:

1. Ensure AtomVM's `ssl` and `ahttp_client` modules are included in the
   application packbeam. Note that [rebar.config](../rebar.config) sets
   `{packbeam, [prune]}`, which strips modules that are not statically
   referenced from the reachable call graph. `ssl`/`ahttp_client` will only be
   packed if `myhome_rest_client` actually calls them; verify with
   `packbeam list` (or temporarily disable `prune`) that both modules are
   present in the built `.avm` before hardware testing.
2. Call `ssl:start/0` once before the first HTTPS connection.
3. Perform a hardware smoke request to:
   - `https://opensky-network.org/api/states/all` with a tiny bounding box.
   - `https://api.adsbdb.com/v0/online`.
4. Verify DNS, SNI, TLS handshake, chunked response handling, response-size
   behavior, connection cleanup, and timeout behavior.
5. Send `Accept-Encoding: identity` so the device does not need gzip support.
6. Confirm the project's JSON decoder can parse a representative OpenSky
   response within available heap. This project uses `tiny_json` (bundled with
   the `tiny_httpd` dependency), not OTP's `json` module. `tiny_json:decode/1`
   returns `{ok, Term}`. OpenSky returns deeply nested arrays of mixed
   null/number/string values, so explicitly verify `tiny_json` handles arrays
   of arrays and JSON `null` on the target build before relying on it.

The current AtomVM `ssl` client exposes `verify_none` but not normal CA-chain
verification. Direct HTTPS therefore encrypts traffic without authenticating
the remote server. Record this limitation prominently. If authenticated TLS is
required, place a small trusted HTTPS-to-HTTP proxy on the local network and
restrict its access to the ESP32; do not silently fall back to public plain
HTTP.

Do not proceed past this gate until the requests work on hardware without
starving the existing application.

## Configuration

Add an `aircraft/0` configuration entry to `myhome_config.erl.template` and the
local configuration:

```erlang
-export([aircraft/0]).

aircraft() ->
    #{
        latitude => 59.3293,
        longitude => 18.0686,
        elevation_m => 25.0,
        search_radius_km => 20.0,
        max_position_age_s => 20,
        min_elevation_deg => 45.0,
        ambiguity_margin_deg => 8.0,
        enrichment => adsbdb,
        hexdb_fallback => true
    }.
```

Validation rules:

- Latitude: `-90.0..90.0`.
- Longitude: `-180.0..180.0`.
- Search radius: default 20 km; cap at 50 km to bound response size.
- Maximum position age: default 20 seconds.
- Minimum elevation: default 45 degrees.
- Configuration is device-side; the browser must not submit arbitrary
  coordinates in the MVP.

The MVP uses anonymous OpenSky access, so no OpenSky credential is stored.
Authenticated OAuth2 client-credentials support can be added later if anonymous
quotas or resolution become insufficient. Client secrets must never be returned
by the HTTP API or committed to the repository.

## Provider Requests

### OpenSky state query

Use one bounded request:

```text
GET https://opensky-network.org/api/states/all
    ?lamin=<south>&lomin=<west>&lamax=<north>&lomax=<east>&extended=1
```

Compute the bounding box from the configured radius:

```text
latitude_delta  = radius_km / 111.32
longitude_delta = radius_km / (111.32 * cos(latitude))
```

Clamp bounds at the poles and split the query only if a future installation
crosses the antimeridian. For the current use case, keep the box below 25 square
degrees so an OpenSky request costs one state credit.

Relevant OpenSky state-vector indexes:

| Index | Field | Use |
|------:|-------|-----|
| 0 | `icao24` | Stable lookup key for enrichment |
| 1 | `callsign` | Flight/aircraft callsign; trim spaces |
| 3 | `time_position` | Staleness check |
| 4 | `last_contact` | Diagnostic freshness |
| 5 | `longitude` | Candidate position |
| 6 | `latitude` | Candidate position |
| 7 | `baro_altitude` | Fallback altitude, metres |
| 8 | `on_ground` | Reject ground vehicles/aircraft |
| 9 | `velocity` | Display, metres/second |
| 10 | `true_track` | Display, degrees |
| 11 | `vertical_rate` | Display, metres/second |
| 13 | `geo_altitude` | Preferred geometric altitude, metres |
| 16 | `position_source` | Diagnostic source |
| 17 | `category` | Aircraft category when `extended=1` |

Reject rows with missing ICAO24, latitude, longitude, altitude, or position
time. Prefer geometric altitude and fall back to barometric altitude while
marking which source was used.

### ADSBDB enrichment

For the selected ICAO24 and a non-empty callsign, use the combined endpoint:

```text
GET https://api.adsbdb.com/v0/aircraft/<ICAO24>?callsign=<CALLSIGN>
```

Without a callsign, query only the aircraft endpoint. Expected metadata includes
registration, type, manufacturer, registered owner/operator, airline, route,
and optional photo URLs.

Treat enrichment as optional. A valid OpenSky candidate remains a successful
result if ADSBDB returns `404`, malformed data, a timeout, or incomplete route
information.

### HexDB fallback

If enabled, use HexDB only for fields still missing after ADSBDB:

```text
GET https://hexdb.io/api/v1/aircraft/<ICAO24>
GET https://hexdb.io/api/v1/route/icao/<CALLSIGN>
```

Do not call both providers unconditionally. This limits latency, external
requests, and heap use.

## Candidate Geometry and Ranking

For each valid state vector:

1. Compute horizontal great-circle distance with the haversine formula.
2. Compute initial bearing from the observer to the aircraft.
3. Determine height above observer:

   ```text
   relative_height_m = aircraft_altitude_m - observer_elevation_m
   ```

4. Reject candidates with non-positive relative height, excessive distance,
   stale positions, or `on_ground = true`.
5. Estimate elevation angle:

   ```text
   elevation_deg = atan2(relative_height_m, horizontal_distance_m) * 180 / pi
   ```

6. Sort by elevation descending, then position freshness descending, then
   horizontal distance ascending.

The highest-elevation candidate is the primary result. Return up to three
ranked candidates when useful. Confidence is derived from observable data, not
provider branding:

| Confidence | Suggested rule |
|------------|----------------|
| `high` | Elevation >= 60 degrees, position age <= 10 s, and lead >= 8 degrees |
| `medium` | Elevation >= 45 degrees and position age <= 20 s |
| `ambiguous` | Top candidates are within the configured ambiguity margin |
| `none` | No candidate meets minimum elevation and freshness requirements |

If `math:atan2/2` is unavailable on the target AtomVM build, compare candidates
using the ratio `relative_height_m / horizontal_distance_m` and use a pure
approximation only for the displayed angle. The feasibility gate must verify the
required math functions.

## HTTP API

### Identify aircraft

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/aircraft/identify` | Run one scan and return ranked candidates |

The body is empty. Device configuration supplies the observer location and
thresholds.

Example response:

```json
{
  "status": "ok",
  "confidence": "high",
  "observed_at": 1784203200,
  "candidate": {
    "icao24": "4ac9e1",
    "callsign": "SAS1421",
    "registration": "SE-ROJ",
    "manufacturer": "Airbus",
    "model": "A320neo",
    "airline": "Scandinavian Airlines",
    "registered_owner_operator": "SAS",
    "origin": {"icao": "ESSA", "iata": "ARN", "name": "Stockholm Arlanda"},
    "destination": {"icao": "EKCH", "iata": "CPH", "name": "Copenhagen"},
    "altitude_m": 10600,
    "altitude_source": "geometric",
    "distance_km": 2.1,
    "bearing_deg": 224.0,
    "elevation_deg": 78.0,
    "track_deg": 210.0,
    "speed_mps": 230.0,
    "position_age_s": 6,
    "photo_url": null
  },
  "alternatives": []
}
```

Expected no-result response:

```json
{
  "status": "ok",
  "confidence": "none",
  "candidate": null,
  "alternatives": [],
  "message": "No recent aircraft found above the elevation threshold"
}
```

Provider and transport failures should use a stable error code:

```json
{
  "status": "error",
  "code": "opensky_timeout",
  "message": "The aircraft service did not respond in time"
}
```

Suggested error codes include `not_configured`, `network_unavailable`,
`dns_failed`, `tls_failed`, `opensky_timeout`, `opensky_rate_limited`,
`opensky_bad_response`, and `busy`.

## Module Responsibilities

### `myhome_rest_client`

A small adapter over AtomVM `ahttp_client`:

- Start SSL once and open HTTPS connections with SNI.
- Send GET requests with `Connection: close`, `Accept: application/json`, and
  `Accept-Encoding: identity`.
- Collect content-length or chunked response bodies with a strict byte limit.
- Enforce connect/read/total timeouts.
- Always close sockets.
- Return `{ok, Status, Headers, Body}` or normalized error tuples.
- Never log authorization headers or future client secrets.

Initial response-body cap: 256 KiB for the bounded OpenSky response and 32 KiB
for enrichment responses. Tune these values during hardware testing.

### `myhome_aircraft_geo`

Pure functions for:

- Bounding-box construction.
- OpenSky state-vector normalization.
- Haversine distance and bearing.
- Elevation calculation.
- Filtering, sorting, ambiguity detection, and confidence assignment.

Keeping this module pure makes nearly all feature logic testable under desktop
Erlang without network access.

### `myhome_aircraft`

A supervised `gen_server` responsible for:

- Loading and validating configuration.
- Rejecting concurrent identification attempts with `busy`.
- Executing exactly one OpenSky query per manual action.
- Selecting candidates before enrichment.
- Enriching only the primary candidate.
- Optionally caching ICAO24 metadata for the current boot.
- Returning normalized maps to the HTTP handler.
- Logging concise, ASCII-only diagnostics. All runtime log and
  `io_lib:format` strings must stay pure ASCII: `myhome_log` builds messages
  with `iolist_to_binary/1`, which rejects codepoints > 255, so a stray
  em-dash, smart quote, or degree sign silently drops the log line. Use `-`
  and `deg` in messages, never non-ASCII symbols.

Use an explicit call timeout of approximately 30 seconds; do not rely on the
five-second `gen_server:call/2` default. Apply shorter per-provider deadlines so
the total remains bounded.

### `myhome_http_handler`

- Add the documented route and endpoint header comment.
- Call `myhome_aircraft:identify/0` with the explicit timeout.
- Map stable service results to JSON without exposing raw exceptions.
- Preserve the existing generic error handling for unrelated routes.
- Encode responses with `tiny_json:encode/1` via the existing `json_reply/1`
  helper, matching every other route in `myhome_http_handler`.
- Return the service's own normalized error map explicitly. The handler's
  top-level catch maps any `exit:{timeout,_}` to a generic
  "request timed out" reply (and this catch has previously mislabelled slow
  WiZ calls), so the aircraft path must resolve its own
  `opensky_timeout`/`busy` results before that catch can fire.

### Dashboard

- Add an aircraft card and one Identify button.
- Do not invoke identification from startup refreshes, `setInterval`, or the
  event long-poll loop.
- Render partial enrichment safely.
- Clearly show confidence, data age, and ambiguity.
- Treat provider photo URLs as optional external content.

## Supervision and Application Integration

Add `myhome_aircraft` as a permanent worker under `myhome_sup`. A worker restart
must clear only in-flight work and the optional metadata cache; it must not
impact the HTTP server, lights, sensors, or BLE bridge.

Ensure application packaging includes every runtime module needed by
`ahttp_client` and `ssl` (JSON is handled by the already-bundled `tiny_json`).
Because `{packbeam, [prune]}` is enabled, these modules are packed only if
reachable from a called function; keep at least one direct reference in
`myhome_rest_client`. Update application declarations only as required by
AtomVM's packaging model, verified during Phase 0.

## Timeouts and Resource Limits

Suggested starting limits:

| Operation | Limit |
|-----------|-------|
| Whole identification request | 30 s |
| OpenSky connect + response | 12 s |
| ADSBDB enrichment | 8 s |
| Optional HexDB fallback | 6 s |
| OpenSky response body | 256 KiB |
| Enrichment response body | 32 KiB |
| Returned alternatives | 3 |
| Concurrent identifications | 1 |

If enrichment reaches its deadline, return the OpenSky identification without
enrichment rather than failing the whole action.

## Error Handling

- **No network:** Return `network_unavailable`; leave other services running.
- **OpenSky `401`/`403`:** Return an authentication/configuration error.
- **OpenSky `429`:** Return `opensky_rate_limited`; do not automatically retry.
- **OpenSky `5xx` or timeout:** Return a provider error; do not query enrichment.
- **Malformed/oversized JSON:** Abort parsing and return `opensky_bad_response`.
- **No qualifying aircraft:** Return `status=ok`, `confidence=none`.
- **Missing callsign:** Identify by ICAO24/registration when possible; omit route.
- **Enrichment failure:** Return the positional candidate with an
  `enrichment_status` field and partial metadata.
- **Concurrent click/request:** Return `busy`; do not start a second provider
  request.
- **Worker crash:** Supervisor restarts only `myhome_aircraft`.

## Testing Strategy

### Desktop EUnit tests

Add fixture-driven tests for:

- Bounding boxes at ordinary latitudes, near poles, and near the antimeridian.
- OpenSky vectors with null/missing fields and trailing callsign spaces.
- Geometric-altitude preference and barometric fallback.
- Distance, bearing, and elevation calculations with known coordinates.
- Freshness, ground-state, radius, and elevation filtering.
- Candidate ranking and ambiguity thresholds.
- Confidence classification.
- OpenSky and ADSBDB JSON normalization.
- Stable provider-error mapping.
- Partial enrichment behavior.

Network tests must use a fake transport or fixture bodies; ordinary unit tests
must not depend on live external APIs.

### HTTP client tests

Use a local test server under desktop Erlang to cover:

- Content-Length and chunked bodies.
- Fragmented headers/body.
- Non-2xx status codes.
- Body-size limits.
- Connection close and timeout behavior.

### Hardware validation

On the ESP32-S3:

1. Run the Phase 0 provider smoke tests.
2. Record free heap before, during, and after identification.
3. Repeat identification several times and verify sockets and heap are released.
4. Trigger light, WiZ, sensor, and BLE requests during a slow provider response.
5. Verify a second Identify action returns `busy` without destabilizing the app.
6. Compare one result with the OpenSky map or another flight tracker at the same
   timestamp.
7. Verify no automatic request occurs after boot or while the dashboard remains
   open.

## Documentation Updates

After implementation:

- Add the endpoint, configuration, limitations, and dashboard behavior to the
  project README.
- Add a Make target such as `make aircraft` for a manual command-line request.
- Document anonymous OpenSky credit use and current provider rate limits.
- Document the AtomVM TLS verification limitation and any local proxy setup.
- State that aircraft registry and route data may be stale or incomplete.

## Implementation Order

1. Complete the AtomVM HTTPS/JSON feasibility gate.
2. Implement and test `myhome_rest_client` with strict timeouts and body caps.
3. Implement pure geometry, state normalization, ranking, and confidence logic.
4. Implement OpenSky request construction and response parsing.
5. Implement ADSBDB enrichment and optional HexDB fallback.
6. Add the manually triggered `myhome_aircraft` worker.
7. Add supervision and configuration.
8. Add `POST /api/aircraft/identify`.
9. Add the dashboard card with no polling.
10. Run desktop tests and hardware resource/concurrency validation.
11. Update README and Makefile documentation.

## Acceptance Criteria

- No external aircraft request is made at boot or on a timer.
- One button press or API call causes at most one OpenSky state query.
- Only the selected aircraft is enriched, except for an explicitly enabled
  fallback after a failed primary lookup.
- A qualifying nearby aircraft produces a ranked, confidence-labelled result.
- No qualifying aircraft produces a successful no-result response.
- Missing enrichment does not discard a valid OpenSky candidate.
- Requests finish or time out within 30 seconds.
- Concurrent requests do not create duplicate provider traffic.
- Provider, DNS, TLS, JSON, and rate-limit failures do not crash unrelated
  supervised services.
- Unit tests run without internet access.
- Hardware testing confirms bounded heap use and no socket leak.
- The dashboard never polls this endpoint automatically.

## Future Extensions

- OpenSky OAuth2 client-credentials authentication with token caching.
- A trusted local proxy that performs certificate verification and provider
  aggregation.
- User-selectable alternatives when multiple aircraft have similar elevation.
- Optional short-lived last-result display after a page reload.
- Local ADS-B receiver integration for lower latency and better coverage.
- Voice-assistant or MCP action that invokes the same manual endpoint.
