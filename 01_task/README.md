# some-tasks

```bash
docker compose up -d
```

Если не сработало при docker compose  

```bash
docker compose exec -T postgres psql -U appuser -d app -f /docker-entrypoint-initdb.d/02_schema.sql
docker compose exec -T postgres psql -U appuser -d app -f /docker-entrypoint-initdb.d/02_seed.sql
```


Получаем начало и конец окна  

```sql
WITH now_utc AS (
  SELECT now() AT TIME ZONE 'UTC' AS n
)
SELECT 
  date_trunc('minute', n) 
    - ((EXTRACT(minute FROM n)::int % 10)) * interval '1 minute' 
    - interval '10 minutes' AS t_start,
  date_trunc('minute', n) 
    - ((EXTRACT(minute FROM n)::int % 10)) * interval '1 minute' AS t_end
FROM now_utc;
```


Два окна их наших лидов  
- A: [2025-09-05 12:20; 12:30),
- B: [2025-09-05 12:30; 12:40).

Коэффициенты: **0..10 → 1.00**, **11..50 → 0.90**, **51+ → 0.80**

```sql
WITH counts AS (
    SELECT l.product_id, l.geo_id, COUNT(*) AS lead_count
    FROM leads l
    WHERE l.created_at >= '2025-09-05 12:20:00+00'
      AND l.created_at <  '2025-09-05 12:30:00+00'
    GROUP BY l.product_id, l.geo_id
),
     mul AS (
         SELECT
             c.product_id,
             c.geo_id,
             CASE
                 WHEN c.lead_count >= 51 THEN 0.80
                 WHEN c.lead_count >= 11 THEN 0.90
                 ELSE 1.00
                 END::NUMERIC(6,4) AS multiplier
         FROM counts c
     )
INSERT INTO price_windows (product_id, geo_id, valid_from, valid_to, multiplier, final_price)
SELECT
    m.product_id,
    m.geo_id,
    '2025-09-05 12:20:00+00'::timestamptz AS valid_from,
    '2025-09-05 12:30:00+00'::timestamptz AS valid_to,
    m.multiplier,
    ROUND(pgp.base_price * m.multiplier, 2) AS final_price
FROM mul m
         JOIN product_geo_prices pgp
              ON pgp.product_id = m.product_id AND pgp.geo_id = m.geo_id
ON CONFLICT (product_id, geo_id, valid_from) DO UPDATE
    SET multiplier  = EXCLUDED.multiplier,
        final_price = EXCLUDED.final_price,
        valid_to    = EXCLUDED.valid_to;
```

```sql
WITH counts AS (
  SELECT l.product_id, l.geo_id, COUNT(*) AS lead_count
  FROM leads l
  WHERE l.created_at >= '2025-09-05 12:30:00+00'
    AND l.created_at <  '2025-09-05 12:40:00+00'
  GROUP BY l.product_id, l.geo_id
),
mul AS (
  SELECT
    c.product_id,
    c.geo_id,
    CASE
      WHEN c.lead_count >= 51 THEN 0.80
      WHEN c.lead_count >= 11 THEN 0.90
      ELSE 1.00
    END::NUMERIC(6,4) AS multiplier
  FROM counts c
)
INSERT INTO price_windows (product_id, geo_id, valid_from, valid_to, multiplier, final_price)
SELECT
  m.product_id,
  m.geo_id,
  '2025-09-05 12:30:00+00'::timestamptz AS valid_from,
  '2025-09-05 12:40:00+00'::timestamptz AS valid_to,
  m.multiplier,
  ROUND(pgp.base_price * m.multiplier, 2) AS final_price
FROM mul m
JOIN product_geo_prices pgp
  ON pgp.product_id = m.product_id AND pgp.geo_id = m.geo_id
ON CONFLICT (product_id, geo_id, valid_from) DO UPDATE
SET multiplier  = EXCLUDED.multiplier,
    final_price = EXCLUDED.final_price,
    valid_to    = EXCLUDED.valid_to;
```


Посмореть что вставилось  

```sql
SELECT product_id, geo_id, valid_from, valid_to, multiplier, final_price
FROM price_windows
ORDER BY valid_from, product_id, geo_id;
```


Чтение актуальной цены

```sql
SELECT
  pw.product_id, pw.geo_id,
  pw.final_price, pw.multiplier,
  g.currency,
  pw.valid_from, pw.valid_to
FROM price_windows pw
JOIN geos g ON g.id = pw.geo_id
WHERE pw.product_id = 1      -- товар
  AND pw.geo_id = 1          -- регион
  AND '2025-09-05 12:35:00+00'::timestamptz >= pw.valid_from
  AND '2025-09-05 12:35:00+00'::timestamptz <  pw.valid_to
ORDER BY pw.valid_from DESC
LIMIT 1;

```