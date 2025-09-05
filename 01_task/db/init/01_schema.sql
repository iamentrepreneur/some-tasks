-- Схема для PostgreSQL

-- 1) Товары
CREATE TABLE IF NOT EXISTS products
(
    id   BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL
);

-- 2) Регионы (ГЕО) с валютой
CREATE TABLE IF NOT EXISTS geos
(
    id       BIGSERIAL PRIMARY KEY,
    code     TEXT NOT NULL UNIQUE, -- 'RU','US',...
    currency TEXT NOT NULL         -- 'RUB','USD',...
);

-- 3) Базовые цены товара по ГЕО (уже с доставкой)
CREATE TABLE IF NOT EXISTS product_geo_prices
(
    product_id BIGINT         NOT NULL REFERENCES products (id),
    geo_id     BIGINT         NOT NULL REFERENCES geos (id),
    base_price NUMERIC(12, 2) NOT NULL,
    PRIMARY KEY (product_id, geo_id)
);

-- 4) Лиды (события)
CREATE TABLE IF NOT EXISTS leads
(
    id         BIGSERIAL PRIMARY KEY,
    product_id BIGINT      NOT NULL REFERENCES products (id),
    geo_id     BIGINT      NOT NULL REFERENCES geos (id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 5) Итоговые цены по 10-минутным окнам (история пересчётов)
CREATE TABLE IF NOT EXISTS price_windows
(
    product_id  BIGINT         NOT NULL REFERENCES products (id),
    geo_id      BIGINT         NOT NULL REFERENCES geos (id),
    valid_from  TIMESTAMPTZ    NOT NULL, -- начало окна (включ.)
    valid_to    TIMESTAMPTZ    NOT NULL, -- конец окна (исключ.)
    multiplier  NUMERIC(6, 4)  NOT NULL, -- 0.80, 0.90, 1.00 ...
    final_price NUMERIC(12, 2) NOT NULL, -- base_price * multiplier
    PRIMARY KEY (product_id, geo_id, valid_from)
);

-- Индексы для скорости выборок
CREATE INDEX IF NOT EXISTS leads_pgid_created_idx
    ON leads (product_id, geo_id, created_at);

CREATE INDEX IF NOT EXISTS price_windows_lookup_idx
    ON price_windows (product_id, geo_id, valid_from, valid_to);
