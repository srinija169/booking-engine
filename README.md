# High-Concurrency Movie Ticket Booking Engine

A MySQL-backed movie ticket booking database design for a BookMyShow-style platform. The assignment covers normalized relational modeling, show discovery, temporary seat holds, payment idempotency, indexing, and concurrency-test design.

## Deliverables

- `database/high_concurrency_booking_engine.sql` — MySQL 8 schema, sample data, show-listing query, and reference transaction snippets.
- `docs/high_concurrency_booking_engine_submission.pdf` — design rationale, normalization, concurrency architecture, indexing, and load-test plan.

## Technology choices

- **MySQL 8 / InnoDB** is the source of truth for seat inventory and booking state.
- **Redis** provides short-lived, per-show/per-seat contention locks with TTL.
- **Payment webhook deduplication** uses a unique provider/event identifier.
- All timestamps are stored in UTC; theatre-local date boundaries are converted by the application.

## Quick start

```bash
mysql -u <username> -p < database/high_concurrency_booking_engine.sql
```

The SQL script creates and selects the `bms_booking` database and inserts sample rows. Review the comments before running the application-oriented transaction examples: parameter placeholders are illustrative and must be bound by a MySQL driver.

## P2: list shows for a theatre and date

The query filters a half-open UTC interval `[day_start_utc, next_day_start_utc)`, joins shows to screens and movies, and sorts chronologically. This avoids applying `DATE()` to the indexed timestamp column.

## Concurrency invariants

1. One inventory row exists per `(show_id, seat_id)`.
2. A seat hold is written only after locking its MySQL inventory row with `SELECT ... FOR UPDATE`.
3. A booking is confirmed only while its hold is valid and after payment verification.
4. Expiry workers re-check status and expiry before releasing seats.
5. Provider webhook events are unique per `(provider, provider_event_id)`.

Redis is an optimization and coordination layer, not the durable correctness boundary.

## Load-test plan

The PDF defines same-seat stampede, overlapping-seat burst, expiry race, duplicate webhook, payment-after-expiry, and read-burst scenarios. No benchmark result is claimed: run the scenarios in a production-like environment and record p50/p95/p99 latency, throughput, error rate, deadlocks, and invariant violations.

## Important production notes

- Bind all user input through prepared statements.
- Verify payment-provider signatures and reconcile amount, currency, and booking identity.
- Keep external payment calls outside database transactions.
- Add an outbox for reliable post-commit notifications/events.
- Validate that every `show_seats.seat_id` belongs to the screen assigned to that show when generating inventory.
- Run `EXPLAIN ANALYZE` with representative data before tuning indexes.

## Assignment

P1: entities, attributes, DDL, sample records, normalization, and concurrency strategy.  
P2: show listing for a given theatre and date.
