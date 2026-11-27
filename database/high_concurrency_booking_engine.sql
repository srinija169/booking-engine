-- High-Concurrency Movie Ticket Booking Engine
-- Target: MySQL 8.0.16+ (InnoDB; enforced CHECK constraints)
-- Run this file in a fresh schema. It creates the database objects and sample data.
-- All timestamps are stored in UTC. Convert at the application boundary.

CREATE DATABASE IF NOT EXISTS bms_booking
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE bms_booking;

SET time_zone = '+00:00';

-- Drop in dependency order to make this script re-runnable in a development schema.
DROP TABLE IF EXISTS payment_webhook_events;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS booking_seats;
DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS show_seats;
DROP TABLE IF EXISTS shows;
DROP TABLE IF EXISTS seats;
DROP TABLE IF EXISTS screens;
DROP TABLE IF EXISTS movies;
DROP TABLE IF EXISTS theatres;
DROP TABLE IF EXISTS cities;
DROP TABLE IF EXISTS users;

CREATE TABLE cities (
    city_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    city_name VARCHAR(100) NOT NULL,
    state_name VARCHAR(100) NOT NULL,
    country_code CHAR(2) NOT NULL DEFAULT 'IN',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (city_id),
    UNIQUE KEY uq_city_state_country (city_name, state_name, country_code)
) ENGINE=InnoDB;

CREATE TABLE users (
    user_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name VARCHAR(150) NOT NULL,
    email VARCHAR(254) NOT NULL,
    phone VARCHAR(20) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_email (email),
    UNIQUE KEY uq_users_phone (phone)
) ENGINE=InnoDB;

CREATE TABLE theatres (
    theatre_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    city_id BIGINT UNSIGNED NOT NULL,
    theatre_name VARCHAR(180) NOT NULL,
    street_address VARCHAR(255) NOT NULL,
    postal_code VARCHAR(12) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (theatre_id),
    KEY ix_theatres_city (city_id, is_active),
    CONSTRAINT fk_theatres_city FOREIGN KEY (city_id)
      REFERENCES cities(city_id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE movies (
    movie_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    title VARCHAR(200) NOT NULL,
    language VARCHAR(60) NOT NULL,
    duration_minutes SMALLINT UNSIGNED NOT NULL,
    certificate VARCHAR(10) NULL,
    release_date DATE NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (movie_id),
    KEY ix_movies_title (title),
    CONSTRAINT chk_movie_duration CHECK (duration_minutes > 0)
) ENGINE=InnoDB;

CREATE TABLE screens (
    screen_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    theatre_id BIGINT UNSIGNED NOT NULL,
    screen_name VARCHAR(80) NOT NULL,
    screen_format VARCHAR(40) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (screen_id),
    UNIQUE KEY uq_screen_name_per_theatre (theatre_id, screen_name),
    KEY ix_screens_theatre (theatre_id, is_active),
    CONSTRAINT fk_screens_theatre FOREIGN KEY (theatre_id)
      REFERENCES theatres(theatre_id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE seats (
    seat_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    screen_id BIGINT UNSIGNED NOT NULL,
    row_label VARCHAR(5) NOT NULL,
    seat_number SMALLINT UNSIGNED NOT NULL,
    seat_type VARCHAR(30) NOT NULL DEFAULT 'REGULAR',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (seat_id),
    UNIQUE KEY uq_seat_position (screen_id, row_label, seat_number),
    UNIQUE KEY uq_seat_screen_pair (seat_id, screen_id),
    CONSTRAINT fk_seats_screen FOREIGN KEY (screen_id)
      REFERENCES screens(screen_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_seat_number CHECK (seat_number > 0)
) ENGINE=InnoDB;

CREATE TABLE shows (
    show_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    screen_id BIGINT UNSIGNED NOT NULL,
    movie_id BIGINT UNSIGNED NOT NULL,
    starts_at DATETIME NOT NULL COMMENT 'UTC start timestamp',
    ends_at DATETIME NOT NULL COMMENT 'UTC end timestamp',
    base_price DECIMAL(10,2) NOT NULL,
    show_status ENUM('SCHEDULED','CANCELLED','COMPLETED') NOT NULL DEFAULT 'SCHEDULED',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (show_id),
    KEY ix_shows_screen_start (screen_id, starts_at, show_status),
    KEY ix_shows_movie (movie_id),
    CONSTRAINT fk_shows_screen FOREIGN KEY (screen_id)
      REFERENCES screens(screen_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_shows_movie FOREIGN KEY (movie_id)
      REFERENCES movies(movie_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_show_time CHECK (ends_at > starts_at),
    CONSTRAINT chk_show_price CHECK (base_price >= 0)
) ENGINE=InnoDB;

-- One row per physical seat per show. This is the authoritative seat inventory.
-- Seat state changes are serialized by InnoDB row locks.
CREATE TABLE show_seats (
    show_id BIGINT UNSIGNED NOT NULL,
    seat_id BIGINT UNSIGNED NOT NULL,
    seat_status ENUM('AVAILABLE','HELD','BOOKED','BLOCKED') NOT NULL DEFAULT 'AVAILABLE',
    hold_token BINARY(16) NULL,
    hold_expires_at DATETIME NULL,
    current_booking_id BIGINT UNSIGNED NULL,
    price DECIMAL(10,2) NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (show_id, seat_id),
    KEY ix_show_seats_availability (show_id, seat_status, seat_id),
    KEY ix_show_seats_expiry (seat_status, hold_expires_at),
    CONSTRAINT fk_show_seats_show FOREIGN KEY (show_id)
      REFERENCES shows(show_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_show_seats_seat FOREIGN KEY (seat_id)
      REFERENCES seats(seat_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_show_seat_price CHECK (price >= 0),
    CONSTRAINT chk_hold_fields CHECK (
      (seat_status = 'HELD' AND hold_token IS NOT NULL AND hold_expires_at IS NOT NULL)
      OR
      (seat_status <> 'HELD' AND hold_token IS NULL AND hold_expires_at IS NULL)
    )
) ENGINE=InnoDB;

CREATE TABLE bookings (
    booking_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    booking_reference CHAR(12) NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    show_id BIGINT UNSIGNED NOT NULL,
    booking_status ENUM('PENDING_PAYMENT','CONFIRMED','PAYMENT_FAILED','EXPIRED','CANCELLED') NOT NULL,
    total_amount DECIMAL(12,2) NOT NULL,
    currency CHAR(3) NOT NULL DEFAULT 'INR',
    hold_token BINARY(16) NOT NULL,
    hold_expires_at DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (booking_id),
    UNIQUE KEY uq_booking_reference (booking_reference),
    UNIQUE KEY uq_booking_hold_token (hold_token),
    KEY ix_bookings_user_created (user_id, created_at),
    KEY ix_bookings_show_status (show_id, booking_status),
    KEY ix_bookings_expiry (booking_status, hold_expires_at),
    CONSTRAINT fk_bookings_user FOREIGN KEY (user_id)
      REFERENCES users(user_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bookings_show FOREIGN KEY (show_id)
      REFERENCES shows(show_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_booking_amount CHECK (total_amount >= 0)
) ENGINE=InnoDB;

CREATE TABLE booking_seats (
    booking_id BIGINT UNSIGNED NOT NULL,
    show_id BIGINT UNSIGNED NOT NULL,
    seat_id BIGINT UNSIGNED NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (booking_id, seat_id),
    -- This table is booking history; show_seats enforces current inventory state.
    KEY ix_booking_seats_show_seat (show_id, seat_id),
    CONSTRAINT fk_booking_seats_booking FOREIGN KEY (booking_id)
      REFERENCES bookings(booking_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_booking_seats_show_seat FOREIGN KEY (show_id, seat_id)
      REFERENCES show_seats(show_id, seat_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_booking_seat_price CHECK (unit_price >= 0)
) ENGINE=InnoDB;

ALTER TABLE show_seats
  ADD CONSTRAINT fk_show_seats_current_booking FOREIGN KEY (current_booking_id)
  REFERENCES bookings(booking_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE TABLE payments (
    payment_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    booking_id BIGINT UNSIGNED NOT NULL,
    provider VARCHAR(40) NOT NULL,
    provider_payment_id VARCHAR(120) NULL,
    idempotency_key VARCHAR(120) NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    currency CHAR(3) NOT NULL DEFAULT 'INR',
    payment_status ENUM('INITIATED','AUTHORIZED','CAPTURED','FAILED','REFUNDED') NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (payment_id),
    UNIQUE KEY uq_payment_idempotency (provider, idempotency_key),
    UNIQUE KEY uq_provider_payment (provider, provider_payment_id),
    KEY ix_payments_booking (booking_id, payment_status),
    CONSTRAINT fk_payments_booking FOREIGN KEY (booking_id)
      REFERENCES bookings(booking_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_payment_amount CHECK (amount >= 0)
) ENGINE=InnoDB;

CREATE TABLE payment_webhook_events (
    webhook_event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider VARCHAR(40) NOT NULL,
    provider_event_id VARCHAR(150) NOT NULL,
    payment_id BIGINT UNSIGNED NULL,
    event_type VARCHAR(80) NOT NULL,
    payload JSON NOT NULL,
    processing_status ENUM('RECEIVED','PROCESSED','FAILED') NOT NULL DEFAULT 'RECEIVED',
    received_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at DATETIME NULL,
    PRIMARY KEY (webhook_event_id),
    UNIQUE KEY uq_provider_event (provider, provider_event_id),
    KEY ix_webhook_status_received (processing_status, received_at),
    CONSTRAINT fk_webhook_payment FOREIGN KEY (payment_id)
      REFERENCES payments(payment_id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB;

-- Sample data
INSERT INTO cities (city_id, city_name, state_name, country_code)
VALUES (1, 'Chennai', 'Tamil Nadu', 'IN');
INSERT INTO users (user_id, full_name, email, phone) VALUES
(1, 'Aarav Kumar', 'aarav@example.com', '+919900000001'),
(2, 'Meera Iyer', 'meera@example.com', '+919900000002');
INSERT INTO theatres (theatre_id, city_id, theatre_name, street_address, postal_code)
VALUES (1, 1, 'PVR Marina Mall', 'OMR, Chennai', '600119');
INSERT INTO movies (movie_id, title, language, duration_minutes, certificate, release_date)
VALUES
(1, 'The Last Voyage', 'English', 142, 'UA', '2026-11-20'),
(2, 'Chennai Express 2', 'Tamil', 151, 'U', '2026-11-21');
INSERT INTO screens (screen_id, theatre_id, screen_name, screen_format) VALUES
(1, 1, 'Screen 1', 'IMAX'), (2, 1, 'Screen 2', '2D');
INSERT INTO seats (seat_id, screen_id, row_label, seat_number, seat_type) VALUES
(1, 1, 'A', 1, 'PREMIUM'), (2, 1, 'A', 2, 'PREMIUM'),
(3, 1, 'A', 3, 'PREMIUM'), (4, 2, 'B', 1, 'REGULAR'),
(5, 2, 'B', 2, 'REGULAR');
INSERT INTO shows (show_id, screen_id, movie_id, starts_at, ends_at, base_price, show_status) VALUES
(1, 1, 1, '2026-11-27 10:00:00', '2026-11-27 12:22:00', 250.00, 'SCHEDULED'),
(2, 1, 1, '2026-11-27 14:00:00', '2026-11-27 16:22:00', 280.00, 'SCHEDULED'),
(3, 2, 2, '2026-11-27 11:30:00', '2026-11-27 14:01:00', 180.00, 'SCHEDULED'),
(4, 2, 2, '2026-11-28 18:30:00', '2026-11-28 21:01:00', 220.00, 'SCHEDULED');
INSERT INTO show_seats (show_id, seat_id, seat_status, price) VALUES
(1, 1, 'AVAILABLE', 350.00), (1, 2, 'AVAILABLE', 350.00), (1, 3, 'AVAILABLE', 350.00),
(2, 1, 'AVAILABLE', 380.00), (2, 2, 'AVAILABLE', 380.00), (2, 3, 'AVAILABLE', 380.00),
(3, 4, 'AVAILABLE', 180.00), (3, 5, 'AVAILABLE', 180.00),
(4, 4, 'AVAILABLE', 220.00), (4, 5, 'AVAILABLE', 220.00);

-- P2: list all shows at a theatre for a calendar date.
-- Convert theatre-local day boundaries to UTC before binding these variables.
SET @theatre_id = 1;
SET @day_start_utc = '2026-11-27 00:00:00';
SET @next_day_start_utc = '2026-11-28 00:00:00';
SELECT sh.show_id, m.movie_id, m.title AS movie_title, m.language,
       m.duration_minutes, sc.screen_name, sh.starts_at, sh.ends_at,
       sh.base_price, sh.show_status
FROM shows AS sh
JOIN screens AS sc ON sc.screen_id = sh.screen_id
JOIN movies AS m ON m.movie_id = sh.movie_id
WHERE sc.theatre_id = @theatre_id
  AND sh.starts_at >= @day_start_utc
  AND sh.starts_at < @next_day_start_utc
  AND sh.show_status = 'SCHEDULED'
ORDER BY sh.starts_at ASC, m.title ASC;

-- Concurrency design notes:
-- 1) Acquire Redis keys seatlock:{show_id}:{seat_id} with NX + TTL in ascending seat order.
-- 2) In one InnoDB transaction, SELECT matching show_seats rows FOR UPDATE in seat order.
-- 3) Validate row count and availability; reclaim only expired holds while row locks are held.
-- 4) Conditional UPDATE to HELD; assert ROW_COUNT() equals requested seat count.
-- 5) Insert PENDING_PAYMENT booking + booking_seats snapshot; link current_booking_id; COMMIT.
-- 6) Verify signed payment webhooks, deduplicate by (provider, provider_event_id), and lock payment,
--    booking, and inventory rows. Confirm only if the hold is still valid; otherwise void/refund.
-- 7) Expiry workers select small batches FOR UPDATE SKIP LOCKED and release only selected IDs
--    after rechecking hold token and expiry. Never bulk-release unrelated rows.
-- Redis is advisory coordination; MySQL row locks and conditional state transitions are authoritative.
