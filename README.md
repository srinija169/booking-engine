# High-Concurrency Movie Ticket Booking Engine

A MySQL-backed movie ticket booking database design for a BookMyShow-style platform. The assignment covers normalized relational modeling, show discovery, temporary seat holds, payment idempotency, indexing, and concurrency-test design.

## Repository contents

- database/high_concurrency_booking_engine.sql — MySQL 8 schema, sample data, and executable P2 show-listing query.
- docs/DESIGN.md — normalization, locking strategy, payment/expiry handling, indexing, and load-test plan.

The formatted assignment PDF is supplied separately with the submission; it is not stored in this repository.

## Technology choices

- MySQL 8 / InnoDB is the source of truth for seat inventory and booking state.
- Redis provides short-lived, per-show/per-seat contention locks with TTL.
- Payment webhook deduplication uses a unique provider/event identifier.
- All timestamps are stored in UTC; theatre-local date boundaries are converted by the application.

## Quick start

```bash
mysql -u <username> -p < database/high_concurrency_booking_engine.sql
```

The SQL script creates and selects the bms_booking database and inserts sample rows. The schema and P2 query are executable; the application-level concurrency sequence is documented in docs/DESIGN.md and must be implemented with bound parameters and explicit transaction checks.

## P2: list shows for a theatre and date

The query filters a half-open UTC interval [day_start_utc, next_day_start_utc), joins shows to screens and movies, and sorts chronologically. This avoids applying DATE() to the indexed timestamp column.

## Concurrency invariants

1. One inventory row exists per (show_id, seat_id).
2. A seat hold is written only after locking its MySQL inventory row with SELECT ... FOR UPDATE.
3. A booking is confirmed only while its hold is valid and after payment verification.
4. Expiry workers re-check status, selected row IDs, token, and expiry before releasing seats.
5. Provider webhook events are unique per (provider, provider_event_id).

Redis is an optimization and coordination layer, not the durable correctness boundary.

## Production notes

- Bind all user input through prepared statements.
- Verify payment-provider signatures and reconcile amount, currency, and booking identity.
- Keep external payment calls outside database transactions.
- Add an outbox for reliable post-commit notifications/events.
- Validate that every show_seats.seat_id belongs to the screen assigned to that show when generating inventory.
- Run EXPLAIN ANALYZE with representative data before tuning indexes.

No performance benchmark is claimed. See docs/DESIGN.md for the proposed concurrent test matrix.
