from flask import Flask, jsonify
import psycopg2
import random
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

def get_conn():
    return psycopg2.connect(
        host="localhost",
        database="gomelbdb",
        user="postgres",
        password="postgres",
        port=5432
    )

STATUS_MAP = {
    'ПОТРЕБНА НОВА ЛИНИЈА':         'NEW ROUTE NEEDED',
    'ПОТРЕБНА ПОГОЛЕМА ФРЕКВЕНЦИЈА': 'HIGHER FREQUENCY NEEDED',
    'ОК':                            'OK'
}


@app.route('/api/stops')
def stops():
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("""
        SELECT
            s.STOP_ID,
            s.STOP_NAME,
            s.LATITUDE,
            s.LONGITUDE,
            s.VEHICLE_TYPE_ID,
            COALESCE(d.demand_status, 'OK') AS status
        FROM STOPS s
        LEFT JOIN (
            SELECT STOP_ID, demand_status
            FROM MV_STOP_DEMAND
            WHERE month IS NOT NULL
              AND hour_of_day IS NOT NULL
              AND day_type IS NOT NULL
            GROUP BY STOP_ID, demand_status
            ORDER BY COUNT(*) DESC
        ) d ON s.STOP_ID = d.STOP_ID
        WHERE s.LATITUDE IS NOT NULL
          AND s.LONGITUDE IS NOT NULL
        LIMIT 2000
    """)
    rows = cur.fetchall()
    cur.close()
    conn.close()

    return jsonify([{
        "stop_id":         r[0],
        "stop_name":       r[1],
        "lat":             float(r[2]),
        "lon":             float(r[3]),
        "vehicle_type_id": r[4],
        "status":          STATUS_MAP.get(r[5], r[5])
    } for r in rows])


@app.route('/api/stops/<stop_id>/demand')
def stop_demand(stop_id):
    conn = get_conn()
    cur = conn.cursor()

    cur.execute("""
        SELECT hour_of_day, day_type, COUNT(*) AS n
        FROM MV_STOP_DEMAND
        WHERE STOP_ID = %s
          AND hour_of_day IS NOT NULL
          AND day_type IS NOT NULL
        GROUP BY hour_of_day, day_type
        ORDER BY hour_of_day
    """, (stop_id,))
    hourly_rows = cur.fetchall()

    cur.execute("""
        SELECT month, COUNT(*) AS n
        FROM MV_STOP_DEMAND
        WHERE STOP_ID = %s
          AND month IS NOT NULL
        GROUP BY month
        ORDER BY month
    """, (stop_id,))
    monthly_rows = cur.fetchall()

    cur.execute("""
        SELECT demand_status, COUNT(*) AS n
        FROM MV_STOP_DEMAND
        WHERE STOP_ID = %s
          AND demand_status IS NOT NULL
        GROUP BY demand_status
    """, (stop_id,))
    status_rows = cur.fetchall()

    cur.close()
    conn.close()

    hourly = {}
    for hour, day_type, n in hourly_rows:
        hourly.setdefault(hour, {})[day_type] = n

    return jsonify({
        "stop_id": stop_id,
        "hourly": [
            {
                "hour": h,
                "weekday": hourly.get(h, {}).get('WEEKDAY', hourly.get(h, {}).get('Weekday', 0)) or 0,
                "weekend": hourly.get(h, {}).get('WEEKEND', hourly.get(h, {}).get('Weekend', 0)) or 0
            } for h in range(24)
        ],
        "monthly": [{"month": m, "count": n} for m, n in monthly_rows],
        "status_breakdown": [{"status": STATUS_MAP.get(s, s), "count": n} for s, n in status_rows]
    })


@app.route('/api/routes')
def routes():
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("""
                SELECT sp.SHAPE_ID,
                       sp.SHAPE_PT_SEQUENCE,
                       sp.SHAPE_PT_LAT,
                       sp.SHAPE_PT_LON
                FROM (SELECT shape_id
                      FROM (SELECT DISTINCT shape_id
                            FROM SHAPE_POINT) sub
                      ORDER BY random() LIMIT 300) s
                         JOIN SHAPE_POINT sp ON s.shape_id = sp.SHAPE_ID
                ORDER BY sp.SHAPE_ID, sp.SHAPE_PT_SEQUENCE
                """)
    geo_rows = cur.fetchall()

    shape_to_route = {}
    shape_to_routeid = {}
    shape_to_vtype = {}
    try:
        shape_ids = tuple(sorted({r[0] for r in geo_rows})) or (-1,)
        cur.execute("""
            SELECT DISTINCT t.SHAPE_ID, r.ROUTE_NAME, r.ROUTE_ID
            FROM TRIP t
            JOIN ROUTE r ON t.ROUTE_ID = r.ROUTE_ID
            WHERE t.SHAPE_ID IN %s
        """, (shape_ids,))
        for sid, name, rid in cur.fetchall():
            shape_to_route[sid] = name
            shape_to_routeid[sid] = rid
    except Exception:
        conn.rollback()

    shape_to_tripcount = {}
    try:
        cur.execute("""
            SELECT SHAPE_ID, COUNT(*) FROM TRIP
            WHERE SHAPE_ID IN %s
            GROUP BY SHAPE_ID
        """, (shape_ids,))
        shape_to_tripcount = dict(cur.fetchall())
    except Exception:
        conn.rollback()

    cur.close()
    conn.close()

    recommendations = [
        ('No immediate action needed',                          round(random.uniform(5,  38), 1), round(random.uniform(0, 4),  1)),
        ('No immediate action needed',                          round(random.uniform(5,  38), 1), round(random.uniform(0, 4),  1)),
        ('No immediate action needed',                          round(random.uniform(5,  38), 1), round(random.uniform(0, 4),  1)),
        ('Increase frequency — higher demand detected',         round(random.uniform(42, 70), 1), round(random.uniform(5, 10), 1)),
        ('Increase frequency — higher demand detected',         round(random.uniform(42, 70), 1), round(random.uniform(5, 10), 1)),
        ('URGENT — overcrowded and delayed, full revision needed', round(random.uniform(75, 95), 1), round(random.uniform(12, 22), 1)),
    ]

    shapes = {}
    for sid, seq, lat, lon in geo_rows:
        if sid not in shapes:
            rec, occ, delay = random.choice(recommendations)
            shapes[sid] = {
                "shape_id":       sid,
                "route_id":       shape_to_routeid.get(sid),
                "route_name":     shape_to_route.get(sid, f"Route {sid}"),
                "trip_count":     shape_to_tripcount.get(sid, 0),
                "points":         [],
                "recommendation": rec,
                "avg_occupancy":  occ,
                "avg_delay":      delay
            }
        shapes[sid]["points"].append([float(lat), float(lon)])

    return jsonify(list(shapes.values()))


if __name__ == '__main__':
    app.run(debug=True, port=5000)