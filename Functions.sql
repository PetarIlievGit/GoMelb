-- следни возења за постојка
CREATE OR REPLACE FUNCTION get_upcoming_trips_for_stop(p_stop_id VARCHAR)
RETURNS TABLE (
    route_name      VARCHAR,
    departure_time  TIME,
    headsign        VARCHAR,
    status          VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        r.ROUTE_NAME,
        st.DEPARTURE_TIME,
        t.TRIP_HEADSIGN,
        t.STATUS
    FROM STOP_TIME st
    JOIN TRIP t  ON st.TRIP_ID  = t.TRIP_ID
    JOIN ROUTE r ON t.ROUTE_ID  = r.ROUTE_ID
    WHERE st.STOP_ID = p_stop_id
      AND t.TRIP_DATE = CURRENT_DATE
      AND st.DEPARTURE_TIME >= LOCALTIME
      AND t.STATUS IN ('SCHEDULED', 'IN_PROGRESS')
    ORDER BY st.DEPARTURE_TIME;
END;
$$ LANGUAGE plpgsql;

SELECT * FROM get_upcoming_trips_for_stop('STOP_5');


-- дали патник има активна претплата
CREATE OR REPLACE FUNCTION passenger_has_active_pass(p_passenger_id VARCHAR)
RETURNS BOOLEAN AS $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM SUBSCRIPTION_PASS
    WHERE PASSENGER_ID = p_passenger_id
      AND STATUS = 'ACTIVE'
      AND END_DATE >= CURRENT_DATE;

    RETURN v_count > 0;
END;
$$ LANGUAGE plpgsql;

SELECT passenger_has_active_pass('PASS_42');


-- откажи возење и извести патници
CREATE OR REPLACE FUNCTION cancel_trip(p_trip_id VARCHAR, p_reason TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE TRIP
    SET STATUS = 'CANCELLED'
    WHERE TRIP_ID = p_trip_id;

    INSERT INTO NOTIFICATION (PASSENGER_ID, TRIP_ID, MESSAGE, NOTIFICATION_TYPE, STATUS)
    SELECT DISTINCT
        tk.PASSENGER_ID,
        p_trip_id,
        'Your trip has been cancelled. Reason: ' || p_reason,
        'CANCELLATION',
        'PENDING'
    FROM TICKET tk
    WHERE tk.TRIP_ID = p_trip_id
      AND tk.STATUS = 'VALID';
END;
$$ LANGUAGE plpgsql;

SELECT cancel_trip('TRIP_10', 'Technical issue with the vehicle');


-- пресметај цена со попуст
CREATE OR REPLACE FUNCTION calculate_ticket_price(
    p_fare_rule_id  INT,
    p_discount_id   INT DEFAULT NULL
)
RETURNS NUMERIC AS $$
DECLARE
    v_base_price        NUMERIC;
    v_discount_pct      NUMERIC := 0;
    v_final_price       NUMERIC;
BEGIN
    SELECT PRICE
    INTO v_base_price
    FROM FARE_RULE
    WHERE FARE_RULE_ID = p_fare_rule_id;

    IF p_discount_id IS NOT NULL THEN
        SELECT DISCOUNT_PERCENTAGE
        INTO v_discount_pct
        FROM DISCOUNT
        WHERE DISCOUNT_ID = p_discount_id
          AND (VALID_TO IS NULL OR VALID_TO >= CURRENT_DATE);
    END IF;

    v_final_price := v_base_price - (v_base_price * v_discount_pct / 100);

    RETURN ROUND(v_final_price, 2);
END;
$$ LANGUAGE plpgsql;

SELECT calculate_ticket_price(1);
SELECT calculate_ticket_price(1, 3);