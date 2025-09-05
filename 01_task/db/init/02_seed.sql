-- Очистим таблицы на случай повторного запуска init
TRUNCATE price_windows RESTART IDENTITY;
TRUNCATE leads RESTART IDENTITY;
TRUNCATE product_geo_prices RESTART IDENTITY CASCADE;
TRUNCATE geos RESTART IDENTITY CASCADE;
TRUNCATE products RESTART IDENTITY CASCADE;

-- 1) Товары
INSERT INTO products (name)
VALUES ('Coffee Machine'), -- id = 1
       ('Headphones');
-- id = 2

-- 2) Регионы (ГЕО)
INSERT INTO geos (code, currency)
VALUES ('RU', 'RUB'), -- id = 1
       ('US', 'USD');
-- id = 2

-- 3) Базовые цены товара по ГЕО
INSERT INTO product_geo_prices (product_id, geo_id, base_price)
VALUES (1, 1, 10000.00), -- Coffee Machine в RU = 10 000 RUB
       (1, 2, 199.00),   -- Coffee Machine в US = 199 USD
       (2, 1, 4500.00),  -- Headphones в RU = 4 500 RUB
       (2, 2, 79.00);
-- Headphones в US = 79 USD

-- 4) Лиды
-- Создадим два окна: [2025-09-05 12:20; 12:30) и [12:30; 12:40)

-- Окно A (12:20–12:30)
INSERT INTO leads (product_id, geo_id, created_at)
VALUES (1, 1, '2025-09-05 12:21:00+00'),
       (1, 1, '2025-09-05 12:25:00+00'),
       (1, 2, '2025-09-05 12:22:00+00'),
       (1, 2, '2025-09-05 12:23:00+00'),
       (1, 2, '2025-09-05 12:24:00+00'),
       (2, 1, '2025-09-05 12:26:00+00');

-- Окно B (12:30–12:40)
INSERT INTO leads (product_id, geo_id, created_at)
VALUES (1, 1, '2025-09-05 12:31:00+00'),
       (1, 1, '2025-09-05 12:32:00+00'),
       (1, 1, '2025-09-05 12:33:00+00'),
       (1, 1, '2025-09-05 12:34:00+00'),
       (1, 2, '2025-09-05 12:35:00+00'),
       (2, 1, '2025-09-05 12:36:00+00'),
       (2, 1, '2025-09-05 12:37:00+00'),
       (2, 1, '2025-09-05 12:38:00+00');
