-- димензија за време
CREATE TABLE DIM_TIME AS
SELECT
    d::DATE                                    AS date_key,
    EXTRACT(YEAR  FROM d)::INT                 AS year,
    EXTRACT(MONTH FROM d)::INT                 AS month,
    TO_CHAR(d, 'Month')                        AS month_name,
    EXTRACT(QUARTER FROM d)::INT               AS quarter,
    EXTRACT(HOUR FROM d)                       AS hour_of_day,
    CASE
        WHEN EXTRACT(DOW FROM d) IN (0,6) THEN 'WEEKEND'
        ELSE 'WORKDAY'
    END                                        AS day_type,
    CASE
        WHEN EXTRACT(HOUR FROM d) BETWEEN 7  AND 9  THEN 'MORNING_PEAK'
        WHEN EXTRACT(HOUR FROM d) BETWEEN 16 AND 18 THEN 'EVENING_PEAK'
        WHEN EXTRACT(HOUR FROM d) BETWEEN 10 AND 15 THEN 'MIDDAY'
        WHEN EXTRACT(HOUR FROM d) BETWEEN 19 AND 22 THEN 'EVENING'
        ELSE 'OFF_PEAK'
    END                                        AS time_slot
FROM GENERATE_SERIES('2024-01-01'::DATE, '2026-12-31'::DATE, '1 hour'::INTERVAL) d;

-- централна факт табела за cube аналитика
CREATE TABLE FACT_TRANSPORT AS
SELECT
    t.TRIP_ID,
    t.ROUTE_ID,
    r.ROUTE_NAME,
    t.VEHICLE_ID,
    t.DRIVER_ID,
    t.TRIP_DATE,
    EXTRACT(MONTH FROM t.TRIP_DATE)::INT        AS month,
    EXTRACT(YEAR  FROM t.TRIP_DATE)::INT        AS year,
    EXTRACT(HOUR  FROM t.START_TIME)::INT       AS hour_of_day,
    CASE
        WHEN EXTRACT(DOW FROM t.TRIP_DATE) IN (0,6) THEN 'WEEKEND'
        ELSE 'WORKDAY'
    END                                         AS day_type,
    CASE
        WHEN EXTRACT(HOUR FROM t.START_TIME) BETWEEN 7  AND 9  THEN 'MORNING_PEAK'
        WHEN EXTRACT(HOUR FROM t.START_TIME) BETWEEN 16 AND 18 THEN 'EVENING_PEAK'
        WHEN EXTRACT(HOUR FROM t.START_TIME) BETWEEN 10 AND 15 THEN 'MIDDAY'
        WHEN EXTRACT(HOUR FROM t.START_TIME) BETWEEN 19 AND 22 THEN 'EVENING'
        ELSE 'OFF_PEAK'
    END                                         AS time_slot,
    t.STATUS                                    AS trip_status,
    COUNT(tk.TICKET_ID)                         AS passengers,
    SUM(tk.PRICE)                               AS revenue,
    COALESCE(SUM(dl.DELAY_MINUTES), 0)          AS total_delay_min,
    COALESCE(AVG(dl.DELAY_MINUTES), 0)          AS avg_delay_min,
    COALESCE(AVG(cl.PASSENGER_COUNT * 100.0
        / NULLIF(v.CAPACITY, 0)), 0)            AS avg_occupancy_pct,
    COALESCE(MAX(cl.PASSENGER_COUNT * 100.0
        / NULLIF(v.CAPACITY, 0)), 0)            AS max_occupancy_pct
FROM TRIP          t
JOIN ROUTE         r   ON t.ROUTE_ID   = r.ROUTE_ID
JOIN VEHICLE       v   ON t.VEHICLE_ID = v.VEHICLE_ID
LEFT JOIN TICKET   tk  ON t.TRIP_ID    = tk.TRIP_ID
    AND tk.STATUS NOT IN ('CANCELLED', 'REFUNDED')
LEFT JOIN DELAY_LOG dl ON t.TRIP_ID    = dl.TRIP_ID
LEFT JOIN CAPACITY_LOG cl ON t.TRIP_ID = cl.TRIP_ID
GROUP BY
    t.TRIP_ID, t.ROUTE_ID, r.ROUTE_NAME, t.VEHICLE_ID,
    t.DRIVER_ID, t.TRIP_DATE, t.START_TIME, t.STATUS, v.CAPACITY;

-- главен datacube со сите комбинации
CREATE MATERIALIZED VIEW MV_TRANSPORT_CUBE AS
SELECT
    route_name,
    month,
    year,
    hour_of_day,
    day_type,
    time_slot,
    trip_status,
    COUNT(trip_id)              AS total_trips,
    SUM(passengers)             AS total_passengers,
    SUM(revenue)                AS total_revenue,
    AVG(avg_delay_min)          AS avg_delay_min,
    MAX(total_delay_min)        AS max_delay_min,
    AVG(avg_occupancy_pct)      AS avg_occupancy_pct,
    MAX(max_occupancy_pct)      AS max_occupancy_pct,
    COUNT(*) FILTER (
        WHERE avg_occupancy_pct > 85
    )                           AS overcrowded_trips,
    COUNT(*) FILTER (
        WHERE avg_delay_min > 10
    )                           AS delayed_trips
FROM FACT_TRANSPORT
GROUP BY CUBE(
    route_name,
    month,
    year,
    hour_of_day,
    day_type,
    time_slot,
    trip_status
);

-- детекција на системско доцнење по линија и час
CREATE MATERIALIZED VIEW MV_SCHEDULE_MISMATCH AS
SELECT
    route_name,
    hour_of_day,
    day_type,
    COUNT(trip_id)          AS total_trips,
    AVG(avg_delay_min)      AS avg_delay,
    MAX(total_delay_min)    AS max_delay,
    COUNT(*) FILTER (
        WHERE avg_delay_min > 10
    )                       AS chronic_delay_trips,
    ROUND(COUNT(*) FILTER (
        WHERE avg_delay_min > 10
    ) * 100.0 / NULLIF(COUNT(*), 0), 2) AS chronic_delay_pct,
    CASE
        WHEN AVG(avg_delay_min) > 15 THEN 'КРИТИЧНО — распоредот не соодветствува'
        WHEN AVG(avg_delay_min) > 10 THEN 'ПРОБЛЕМАТИЧНО — потребна корекција'
        WHEN AVG(avg_delay_min) > 5  THEN 'УМЕРЕНО — следење потребно'
        ELSE 'ОК'
    END                     AS schedule_status
FROM FACT_TRANSPORT
GROUP BY ROLLUP(route_name, hour_of_day, day_type);

-- детекција на преполни линии
CREATE MATERIALIZED VIEW MV_OVERCROWDING_ANALYSIS AS
SELECT
    route_name,
    month,
    hour_of_day,
    day_type,
    time_slot,
    AVG(avg_occupancy_pct)      AS avg_occupancy,
    MAX(max_occupancy_pct)      AS peak_occupancy,
    COUNT(trip_id)              AS total_trips,
    COUNT(*) FILTER (
        WHERE avg_occupancy_pct > 85
    )                           AS overcrowded_trips,
    COUNT(*) FILTER (
        WHERE avg_occupancy_pct > 100
    )                           AS over_capacity_trips,
    CASE
        WHEN AVG(avg_occupancy_pct) > 90 THEN 'ИТНО — потребен почест бус'
        WHEN AVG(avg_occupancy_pct) > 75 THEN 'ПРЕПОРАЧАНО — зголеми фреквенција'
        WHEN AVG(avg_occupancy_pct) > 60 THEN 'СЛЕДИ — потенцијален проблем'
        ELSE 'ОК'
    END                         AS recommendation
FROM FACT_TRANSPORT
GROUP BY ROLLUP(route_name, month, hour_of_day, day_type, time_slot);

-- побарувачка по постојка
CREATE MATERIALIZED VIEW MV_STOP_DEMAND AS
SELECT
    s.STOP_ID,
    s.STOP_NAME,
    EXTRACT(MONTH FROM t.TRIP_DATE)::INT    AS month,
    EXTRACT(HOUR  FROM st.DEPARTURE_TIME)   AS hour_of_day,
    CASE
        WHEN EXTRACT(DOW FROM t.TRIP_DATE) IN (0,6) THEN 'WEEKEND'
        ELSE 'WORKDAY'
    END                                     AS day_type,
    COUNT(DISTINCT t.TRIP_ID)               AS total_trips_through,
    COUNT(tk.TICKET_ID)                     AS total_boardings,
    AVG(cl.PASSENGER_COUNT)                 AS avg_passengers_at_stop,
    CASE
        WHEN COUNT(DISTINCT t.TRIP_ID) < 5
         AND COUNT(tk.TICKET_ID) > 100
        THEN 'ПОТРЕБНА НОВА ЛИНИЈА'
        WHEN COUNT(DISTINCT t.TRIP_ID) BETWEEN 5 AND 10
         AND AVG(cl.PASSENGER_COUNT) > 40
        THEN 'ПОТРЕБНА ПОГОЛЕМА ФРЕКВЕНЦИЈА'
        ELSE 'ОК'
    END                                     AS demand_status
FROM STOPS          s
JOIN STOP_TIME     st ON s.STOP_ID   = st.STOP_ID
JOIN TRIP          t  ON st.TRIP_ID  = t.TRIP_ID
LEFT JOIN TICKET   tk ON t.TRIP_ID   = tk.TRIP_ID
LEFT JOIN CAPACITY_LOG cl ON t.TRIP_ID = cl.TRIP_ID
GROUP BY CUBE(s.STOP_ID, s.STOP_NAME,
              EXTRACT(MONTH FROM t.TRIP_DATE)::INT,
              EXTRACT(HOUR FROM st.DEPARTURE_TIME),
              day_type);

-- ако линија доцни дали патниците минуваат на друга
CREATE MATERIALIZED VIEW MV_RIDE_SHIFT_DETECTION AS
WITH delayed_trips AS (
    SELECT
        t.ROUTE_ID,
        t.TRIP_DATE,
        EXTRACT(HOUR FROM t.START_TIME)::INT    AS hour_of_day,
        AVG(dl.DELAY_MINUTES)                   AS avg_delay
    FROM TRIP t
    JOIN DELAY_LOG dl ON t.TRIP_ID = dl.TRIP_ID
    GROUP BY t.ROUTE_ID, t.TRIP_DATE, EXTRACT(HOUR FROM t.START_TIME)::INT
    HAVING AVG(dl.DELAY_MINUTES) > 10
),
normal_trips AS (
    SELECT
        t.ROUTE_ID,
        t.TRIP_DATE,
        EXTRACT(HOUR FROM t.START_TIME)::INT    AS hour_of_day,
        COUNT(tk.TICKET_ID)                     AS passengers
    FROM TRIP t
    LEFT JOIN TICKET tk ON t.TRIP_ID = tk.TRIP_ID
        AND tk.STATUS NOT IN ('CANCELLED', 'REFUNDED')
    GROUP BY t.ROUTE_ID, t.TRIP_DATE, EXTRACT(HOUR FROM t.START_TIME)::INT
)
SELECT
    r.ROUTE_NAME,
    n.TRIP_DATE,
    n.hour_of_day,
    d.avg_delay,
    n.passengers                                AS actual_passengers,
    AVG(n.passengers) OVER (
        PARTITION BY n.ROUTE_ID, n.hour_of_day
    )                                           AS avg_passengers_no_delay,
    ROUND((AVG(n.passengers) OVER (
        PARTITION BY n.ROUTE_ID, n.hour_of_day
    ) - n.passengers) * 100.0 / NULLIF(
        AVG(n.passengers) OVER (
            PARTITION BY n.ROUTE_ID, n.hour_of_day
        ), 0), 2)                               AS passenger_drop_pct,
    CASE
        WHEN (AVG(n.passengers) OVER (
            PARTITION BY n.ROUTE_ID, n.hour_of_day
        ) - n.passengers) > 20
        THEN 'ВЕРОЈАТЕН RIDE SHIFT'
        ELSE 'НОРМАЛНО'
    END                                         AS shift_status
FROM normal_trips    n
JOIN delayed_trips   d USING (ROUTE_ID, TRIP_DATE, hour_of_day)
JOIN ROUTE           r ON n.ROUTE_ID = r.ROUTE_ID;

-- финален предлог за оптимизација
CREATE MATERIALIZED VIEW MV_OPTIMIZATION_RECOMMENDATIONS AS
SELECT
    o.route_name,
    o.hour_of_day,
    o.day_type,
    o.avg_occupancy,
    o.recommendation                            AS occupancy_recommendation,
    s.schedule_status                           AS delay_recommendation,
    s.avg_delay,
    CASE
        WHEN o.avg_occupancy > 90
         AND s.avg_delay > 10
        THEN 'ИТНО — и преполна и доцни, потребна целосна ревизија'
        WHEN o.avg_occupancy > 90
        THEN 'Зголеми фреквенција на возења'
        WHEN s.avg_delay > 10
        THEN 'Корегирај распоред — не соодветствува со сообраќајот'
        ELSE 'Без итни препораки'
    END                                         AS final_recommendation
FROM MV_OVERCROWDING_ANALYSIS  o
JOIN MV_SCHEDULE_MISMATCH      s
    ON  o.route_name  = s.route_name
    AND o.hour_of_day = s.hour_of_day
    AND o.day_type    = s.day_type
WHERE o.avg_occupancy > 60 OR s.avg_delay > 5;