-- додај ново возење
CREATE OR REPLACE PROCEDURE add_trip(
    p_trip_id       VARCHAR,
    p_route_id      VARCHAR,
    p_vehicle_id    VARCHAR,
    p_driver_id     VARCHAR,
    p_trip_date     DATE,
    p_start_time    TIME,
    p_end_time      TIME,
    p_headsign      VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM TRIP WHERE TRIP_ID = p_trip_id) THEN
        RAISE EXCEPTION 'Trip % already exists.', p_trip_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM ROUTE WHERE ROUTE_ID = p_route_id) THEN
        RAISE EXCEPTION 'Route % does not exist.', p_route_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM VEHICLE WHERE VEHICLE_ID = p_vehicle_id) THEN
        RAISE EXCEPTION 'Vehicle % does not exist.', p_vehicle_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM DRIVER WHERE DRIVER_ID = p_driver_id) THEN
        RAISE EXCEPTION 'Driver % does not exist.', p_driver_id;
    END IF;

    INSERT INTO TRIP (TRIP_ID, ROUTE_ID, VEHICLE_ID, DRIVER_ID,
                      TRIP_DATE, START_TIME, END_TIME, TRIP_HEADSIGN, STATUS)
    VALUES (p_trip_id, p_route_id, p_vehicle_id, p_driver_id,
            p_trip_date, p_start_time, p_end_time, p_headsign, 'SCHEDULED');

    RAISE NOTICE 'Trip % has been successfully added.', p_trip_id;
END;
$$;

CALL add_trip('TRIP_99', 'ROUTE_1', 'VEH_1', 'DRV_1',
              CURRENT_DATE, '08:00', '09:00', 'Center');

-- купи билет
CREATE OR REPLACE PROCEDURE buy_ticket(
    p_ticket_id     VARCHAR,
    p_passenger_id  VARCHAR,
    p_trip_id       VARCHAR,
    p_ticket_type   INTEGER,
    p_fare_rule_id  INTEGER DEFAULT NULL,
    p_discount_id   INTEGER DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_price       NUMERIC;
    v_trip_status VARCHAR;
BEGIN
    IF EXISTS (SELECT 1 FROM TICKET WHERE TICKET_ID = p_ticket_id) THEN
        RAISE EXCEPTION 'Ticket % already exists.', p_ticket_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM PASSENGER WHERE PASSENGER_ID = p_passenger_id) THEN
        RAISE EXCEPTION 'Passenger % does not exist.', p_passenger_id;
    END IF;

    SELECT STATUS INTO v_trip_status FROM TRIP WHERE TRIP_ID = p_trip_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Trip % does not exist.', p_trip_id;
    END IF;

    INSERT INTO TICKET (TICKET_ID, PASSENGER_ID, TRIP_ID, TICKET_TYPE_ID,
                        FARE_RULE_ID, DISCOUNT_ID, PURCHASE_DATE, PRICE, STATUS)
    VALUES (p_ticket_id, p_passenger_id, p_trip_id, p_ticket_type,
            p_fare_rule_id, p_discount_id, CURRENT_DATE, v_price, 'VALID');

    RAISE NOTICE 'Ticket % purchased for price %.', p_ticket_id, v_price;
END;
$$;

CALL buy_ticket('TKT_001', 'PASS_1', 'TRIP_99', 1, 2, NULL);

-- евидентирај доцнење и извести патници
CREATE OR REPLACE PROCEDURE report_delay(
    p_trip_id       VARCHAR,
    p_stop_id       VARCHAR,
    p_stop_vt       INTEGER,
    p_delay_min     INTEGER,
    p_reason        TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_delay_id INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM TRIP WHERE TRIP_ID = p_trip_id) THEN
        RAISE EXCEPTION 'Trip % does not exist.', p_trip_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM STOP WHERE STOP_ID = p_stop_id) THEN
        RAISE EXCEPTION 'Stop % does not exist.', p_stop_id;
    END IF;

    INSERT INTO DELAY_LOG (TRIP_ID, STOP_ID, STOP_VT, DELAY_MINUTES, DELAY_REASON)
    VALUES (p_trip_id, p_stop_id, p_stop_vt, p_delay_min, p_reason)
    RETURNING DELAY_ID INTO v_delay_id;

    UPDATE TRIP SET STATUS = 'DELAYED' WHERE TRIP_ID = p_trip_id;

    INSERT INTO NOTIFICATION (PASSENGER_ID, TRIP_ID, DELAY_LOG_ID, MESSAGE, NOTIFICATION_TYPE, STATUS)
    SELECT DISTINCT
        tk.PASSENGER_ID,
        p_trip_id,
        v_delay_id,
        'Your trip is delayed by ' || p_delay_min || ' min. Reason: ' || p_reason,
        'DELAY',
        'PENDING'
    FROM TICKET tk
    WHERE tk.TRIP_ID = p_trip_id
      AND tk.STATUS = 'VALID';

    RAISE NOTICE 'Delay of % min recorded for trip %.', p_delay_min, p_trip_id;
END;
$$;

CALL report_delay('TRIP_99', 'STOP_5', 1, 15, 'Traffic congestion');

-- додели попуст на патник
CREATE OR REPLACE PROCEDURE assign_discount_to_passenger(
    p_passenger_id  VARCHAR,
    p_discount_id   INTEGER,
    p_officer_id    VARCHAR,
    p_expiry_date   DATE DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM PASSENGER WHERE PASSENGER_ID = p_passenger_id) THEN
        RAISE EXCEPTION 'Passenger % does not exist.', p_passenger_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM DISCOUNT WHERE DISCOUNT_ID = p_discount_id) THEN
        RAISE EXCEPTION 'Discount % does not exist.', p_discount_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM OFFICER WHERE OFFICER_ID = p_officer_id) THEN
        RAISE EXCEPTION 'Officer % does not exist.', p_officer_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM PASSENGER_DISCOUNT
        WHERE PASSENGER_ID = p_passenger_id
          AND DISCOUNT_ID = p_discount_id
          AND STATUS = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Passenger % already has this discount.', p_passenger_id;
    END IF;

    INSERT INTO PASSENGER_DISCOUNT (PASSENGER_ID, DISCOUNT_ID, OFFICER_ID,
                                    ASSIGNED_DATE, EXPIRY_DATE, STATUS)
    VALUES (p_passenger_id, p_discount_id, p_officer_id,
            CURRENT_DATE, p_expiry_date, 'ACTIVE');

    RAISE NOTICE 'Discount % assigned to passenger %.', p_discount_id, p_passenger_id;
END;
$$;

CALL assign_discount_to_passenger('PASS_1', 2, 'OFF_1', '2026-12-31');

-- заврши возење
CREATE OR REPLACE PROCEDURE complete_trip(p_trip_id VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM TRIP WHERE TRIP_ID = p_trip_id) THEN
        RAISE EXCEPTION 'Trip % does not exist.', p_trip_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM TRIP
        WHERE TRIP_ID = p_trip_id
          AND STATUS = 'IN_PROGRESS'
    ) THEN
        RAISE EXCEPTION 'Trip % is not currently in progress.', p_trip_id;
    END IF;

    UPDATE TRIP
    SET STATUS = 'COMPLETED', END_TIME = LOCALTIME
    WHERE TRIP_ID = p_trip_id;

    UPDATE TICKET
    SET STATUS = 'USED'
    WHERE TRIP_ID = p_trip_id
      AND STATUS = 'VALID';

    RAISE NOTICE 'Trip % has been completed.', p_trip_id;
END;
$$;

CALL complete_trip('TRIP_99');

-- врати билет
CREATE OR REPLACE PROCEDURE refund_ticket(p_ticket_id VARCHAR)
LANGUAGE plpgsql AS $$
DECLARE
    v_amount    NUMERIC;
    v_pass_id   VARCHAR;
BEGIN

    SELECT PRICE, PASSENGER_ID
    INTO v_amount, v_pass_id
    FROM TICKET
    WHERE TICKET_ID = p_ticket_id
      AND STATUS = 'VALID';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket % does not exist or is not valid.', p_ticket_id;
    END IF;

    UPDATE TICKET SET STATUS = 'REFUNDED' WHERE TICKET_ID = p_ticket_id;

    UPDATE PAYMENT
    SET PAYMENT_STATUS = 'REFUNDED'
    WHERE TICKET_ID = p_ticket_id;

    RAISE NOTICE 'Ticket % refunded. Amount: %.', p_ticket_id, v_amount;
END;
$$;

CALL refund_ticket('TKT_001');

-- закажи распоред за возач
CREATE OR REPLACE PROCEDURE schedule_driver(
    p_driver_id     VARCHAR,
    p_trip_id       VARCHAR,
    p_shift_id      INTEGER,
    p_schedule_date DATE,
    p_shift_start   TIMESTAMP,
    p_shift_end     TIMESTAMP
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM DRIVER WHERE DRIVER_ID = p_driver_id) THEN
        RAISE EXCEPTION 'Driver % does not exist.', p_driver_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM TRIP WHERE TRIP_ID = p_trip_id) THEN
        RAISE EXCEPTION 'Trip % does not exist.', p_trip_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM SHIFT WHERE SHIFT_ID = p_shift_id) THEN
        RAISE EXCEPTION 'Shift % does not exist.', p_shift_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM DRIVER_SCHEDULE
        WHERE DRIVER_ID = p_driver_id
          AND SCHEDULE_DATE = p_schedule_date
    ) THEN
        RAISE EXCEPTION 'Driver % already has a schedule for %.', p_driver_id, p_schedule_date;
    END IF;

    INSERT INTO DRIVER_SCHEDULE (DRIVER_ID, TRIP_ID, SHIFT_ID,
                                  SCHEDULE_DATE, SHIFT_START, SHIFT_END)
    VALUES (p_driver_id, p_trip_id, p_shift_id,
            p_schedule_date, p_shift_start, p_shift_end);

    RAISE NOTICE 'Driver % has been scheduled for %.', p_driver_id, p_schedule_date;
END;
$$;

CALL schedule_driver('DRV_1', 'TRIP_99', 1, CURRENT_DATE, '2026-05-20 07:00', '2026-05-20 15:00');