-- автоматски означи билет за EXPIRED
CREATE OR REPLACE FUNCTION trg_expire_ticket()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.STATUS = 'VALID' AND NEW.PURCHASE_DATE < CURRENT_DATE - INTERVAL '1 day' THEN
        NEW.STATUS := 'EXPIRED';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_ticket_expire
BEFORE INSERT OR UPDATE ON TICKET
FOR EACH ROW EXECUTE FUNCTION trg_expire_ticket();


--спречи бришење на активно возење
CREATE OR REPLACE FUNCTION trg_prevent_vehicle_delete()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM TRIP
        WHERE VEHICLE_ID = OLD.VEHICLE_ID
          AND STATUS IN ('SCHEDULED', 'IN_PROGRESS')
    ) THEN
        RAISE EXCEPTION 'Не може да се избрише возило % — има активни возења.', OLD.VEHICLE_ID;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vehicle_delete
BEFORE DELETE ON VEHICLE
FOR EACH ROW EXECUTE FUNCTION trg_prevent_vehicle_delete();


--автоматски постави статус на pass на EXPIRED
CREATE OR REPLACE FUNCTION trg_expire_pass()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.END_DATE < CURRENT_DATE AND NEW.STATUS = 'ACTIVE' THEN
        NEW.STATUS := 'EXPIRED';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pass_expire
BEFORE INSERT OR UPDATE ON SUBSCRIPTION_PASS
FOR EACH ROW EXECUTE FUNCTION trg_expire_pass();


--спречи двојно закажување на возач
CREATE OR REPLACE FUNCTION trg_prevent_driver_double_schedule()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM DRIVER_SCHEDULE
        WHERE DRIVER_ID = NEW.DRIVER_ID
          AND SCHEDULE_DATE = NEW.SCHEDULE_DATE
          AND DRIVER_SCHEDULE_ID != COALESCE(NEW.DRIVER_SCHEDULE_ID, -1)
    ) THEN
        RAISE EXCEPTION 'Возачот % веќе е закажан за %.', NEW.DRIVER_ID, NEW.SCHEDULE_DATE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_driver_double_schedule
BEFORE INSERT OR UPDATE ON DRIVER_SCHEDULE
FOR EACH ROW EXECUTE FUNCTION trg_prevent_driver_double_schedule();


--автоматска нотификација при ново доцнење
CREATE OR REPLACE FUNCTION trg_notify_on_delay()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO NOTIFICATION (PASSENGER_ID, TRIP_ID, DELAY_LOG_ID, MESSAGE, NOTIFICATION_TYPE, STATUS)
    SELECT DISTINCT
        tk.PASSENGER_ID,
        NEW.TRIP_ID,
        NEW.DELAY_ID,
        'Возењето доцни ' || NEW.DELAY_MINUTES || ' мин. Причина: ' || NEW.DELAY_REASON,
        'DELAY',
        'PENDING'
    FROM TICKET tk
    WHERE tk.TRIP_ID = NEW.TRIP_ID
      AND tk.STATUS = 'VALID';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delay_notification
AFTER INSERT ON DELAY_LOG
FOR EACH ROW EXECUTE FUNCTION trg_notify_on_delay();


--провери дали возилото е активно пред да се закаже ново возење
CREATE OR REPLACE FUNCTION trg_check_vehicle_active()
RETURNS TRIGGER AS $$
DECLARE
    v_status VARCHAR;
BEGIN
    SELECT STATUS INTO v_status
    FROM VEHICLE
    WHERE VEHICLE_ID = NEW.VEHICLE_ID;

    IF v_status != 'ACTIVE' THEN
        RAISE EXCEPTION 'Возилото % не е активно (статус: %).', NEW.VEHICLE_ID, v_status;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_vehicle_active
BEFORE INSERT ON TRIP
FOR EACH ROW EXECUTE FUNCTION trg_check_vehicle_active();