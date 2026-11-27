# Design Notes — High-Concurrency Booking

## P1 — Relational model

The schema separates stable catalog data from show-specific inventory and transaction history.

| Entity | Purpose | Key constraints |
|---|---|---|
| cities | City/state reference | Unique city + state + country |
| users | Customer identity | Unique email and phone |
| theatres | Venue in a city | FK to cities |
| screens | Auditorium within a theatre | Unique screen name per theatre |
| seats | Physical seat layout | Unique screen/row/number |
| movies | Movie catalog | Positive duration |
| shows | Movie scheduled on a screen | Positive interval; indexed screen/start |
| show_seats | Per-show seat inventory | PK(show_id, seat_id); authoritative state |
| bookings | Customer reservation aggregate | Unique booking reference and hold token |
| booking_seats | Immutable seat/price snapshot | FK to booking and show inventory |
| payments | Payment attempts | Provider idempotency key |
| payment_webhook_events | Webhook inbox | Unique provider event ID |

### Normalization

- 1NF: attributes are scalar; seat collections are represented by rows, not comma-separated values.
- 2NF: composite-key inventory and booking-seat tables contain attributes dependent on their full key.
- 3NF: city, theatre, screen, seat, movie, show, user, booking, and payment facts are stored in their own relations.
- BCNF: candidate keys are declared with primary/unique constraints for the modeled dependencies.

booking_seats preserves historical seat and price snapshots. Current availability is read from show_seats.

## P1 — Concurrency strategy

show_seats has one row per (show_id, seat_id). InnoDB is the correctness boundary:

1. Validate requested seats belong to the show's screen.
2. Acquire optional Redis locks (SET key token NX PX 300000) in ascending seat order.
3. Begin a short MySQL transaction.
4. Select requested show_seats rows in ascending seat order using FOR UPDATE.
5. Verify exact row count and that every seat is AVAILABLE or has an expired hold.
6. Conditionally update all requested rows to HELD; assert affected-row count equals requested count.
7. Insert a PENDING_PAYMENT booking and booking_seats snapshots, link inventory rows to the booking, and commit.
8. Release Redis locks only with compare-and-delete using the request token. Keep a short TTL as crash recovery.

Redis is advisory. MySQL row locks and conditional updates remain authoritative.

### Payment and expiry

- Verify provider signatures and compare payment ID, amount, currency, and booking identity.
- Deduplicate webhook retries with unique (provider, provider_event_id).
- Lock payment, booking, and inventory rows before state transitions.
- Confirm only if booking remains PENDING_PAYMENT and the hold is unexpired.
- For payment after expiry, do not resurrect the hold; initiate provider void/refund and reconcile.
- Expiry workers use small batches with FOR UPDATE SKIP LOCKED, then update only selected rows after rechecking token and expiry.
- Never make a network payment call while holding a database transaction open.

### Burst handling

| Scenario | Protection |
|---|---|
| Many users request same seat | Redis contention reduction + MySQL row lock + conditional update |
| Overlapping seat sets | Deterministic lock order; bounded deadlock retry |
| Client retries booking | Stable idempotency key / hold token |
| Duplicate payment webhook | Unique provider event ID |
| Payment after hold expiry | State/expiry recheck; void or refund |
| Expiry worker overlaps payment callback | Row locks and conditional transitions |
| Redis lock expires early | MySQL inventory state prevents double booking |

## P2 — Theatre/date show listing

The SQL file includes the executable query. It uses a half-open UTC range (starts_at >= day_start and starts_at < next_day_start), preserving index use on the timestamp. Convert theatre-local calendar-day boundaries to UTC before binding.

## Indexing

- shows(screen_id, starts_at, show_status) for screen/date lookup.
- show_seats(show_id, seat_status, seat_id) for seat-map availability.
- show_seats(seat_status, hold_expires_at) and bookings(booking_status, hold_expires_at) for expiry scans.
- payments(booking_id, payment_status) for payment history.
- Unique indexes enforce idempotency and natural uniqueness.

Validate plans with EXPLAIN ANALYZE on production-like cardinalities.

## Test plan

1. 100+ concurrent requests for one seat: exactly one hold succeeds.
2. Overlapping seat sets: no seat can be held by two bookings.
3. Hold expiry races with payment callback: only one valid transition wins.
4. Duplicate webhook delivery: one logical event is applied.
5. Payment after expiry: booking remains expired and compensation is recorded.
6. Multi-worker expiry scan: workers process disjoint rows.
7. Read burst: measure p50/p95/p99, throughput, DB CPU, lock waits, and error rate.

No performance benchmark is claimed; run these tests in a production-like environment before production use.