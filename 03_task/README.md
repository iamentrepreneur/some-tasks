# Вопрос по логике

У вас есть хранимые изображения на жестком диске. их количество более 1млн, при этом вес каждой от 10 до 50 мб. Изображения постоянно дополняются. До этого момента они не были никак каталогизированны. В настоящий момент надо организовать, при каждом новом пополнении выполняется определение похожих картинок и пометка данной категории.
Как вы технически будете это организовывать?

## Структура хранения (файлы)

```bash
/images/
  ab/
    cd/
      abcd...1234.jpg
  thumbs/
    ab/cd/abcd...1234_512.jpg
```

Идентификатор = sha256 файла. Это даёт:  
- моментальную детекцию точных дублей,
- идемпотентность (повторная загрузка → ничего не ломает).


## Схема БД

```sql

CREATE TABLE images (
  id             BIGSERIAL PRIMARY KEY,
  file_sha256    TEXT UNIQUE NOT NULL,
  path_original  TEXT NOT NULL,
  width          INT,
  height         INT,
  bytes          BIGINT,
  format         TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Перцептуальные хэши (near-duplicate, дешёво)
CREATE TABLE image_hashes (
  image_id   BIGINT PRIMARY KEY REFERENCES images(id) ON DELETE CASCADE,
  phash64    BIGINT,              -- 64-бит pHash (или два BIGINT для 128)
  dhash64    BIGINT,
  ahash64    BIGINT
);

-- Эмбеддинги (семантика)
-- Вариант A (pgvector):
CREATE TABLE image_embeddings (
  image_id   BIGINT PRIMARY KEY REFERENCES images(id) ON DELETE CASCADE,
  model_ver  TEXT NOT NULL,                      -- 'clip-vit-b32@1'
  emb        VECTOR(512) NOT NULL                -- 512-мерный вектор CLIP
);

-- Вариант B (если Qdrant/Milvus): храним бинарник вектора:
CREATE TABLE image_embeddings (
  image_id   BIGINT PRIMARY KEY REFERENCES images(id) ON DELETE CASCADE,
  model_ver  TEXT NOT NULL,
  emb        BYTEA NOT NULL                         -- float32[512]
);

-- Кластеры (категории похожести)
CREATE TABLE clusters (
  id           BIGSERIAL PRIMARY KEY,
  model_ver    TEXT NOT NULL,                       -- к какой версии эмбеддингов относится
  size         INT NOT NULL DEFAULT 0,
  centroid     BYTEA,                               -- усреднённый вектор (или VECTOR(512))
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE image_cluster (
  image_id   BIGINT PRIMARY KEY REFERENCES images(id) ON DELETE CASCADE,
  cluster_id BIGINT NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  sim_score  REAL                                    -- «насколько» близко к центроиду
);

-- Индексы:
CREATE INDEX ON images (created_at);
-- Для pgvector (ivfflat): 
-- ёCREATE INDEX idx_emb ON image_embeddings USING ivfflat (emb vector_l2_ops) WITH (lists = 200);
-- Затем: ANALYZE image_embeddings;
``` 