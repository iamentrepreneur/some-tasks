# Вопрос по организации кода.

## Схема

```sql
-- Нормализуем "цели" (любой тип/ID превращаем во внутренний ключ)
CREATE TABLE reaction_targets
(
    id          BIGSERIAL PRIMARY KEY,
    target_type TEXT   NOT NULL, -- 'post', 'product', 'comment', ...
    target_id   BIGINT NOT NULL,
    UNIQUE (target_type, target_id)
);

-- Реакции пользователей (одна на пользователя и цель)
-- reaction:  1 = like, -1 = dislike, 0 = нейтрально/удалено
CREATE TABLE reactions
(
    target_uid BIGINT      NOT NULL REFERENCES reaction_targets (id) ON DELETE CASCADE,
    user_id    BIGINT      NOT NULL,
    reaction   SMALLINT    NOT NULL CHECK (reaction IN (-1, 0, 1)),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (target_uid, user_id)
);

CREATE INDEX reactions_user_idx ON reactions (user_id);
CREATE INDEX reactions_target_idx ON reactions (target_uid);

-- Материализованные счётчики (быстрое чтение, мягкая консистентность)
CREATE TABLE reaction_counters
(
    target_uid BIGINT PRIMARY KEY REFERENCES reaction_targets (id) ON DELETE CASCADE,
    likes      BIGINT      NOT NULL DEFAULT 0,
    dislikes   BIGINT      NOT NULL DEFAULT 0,
    score      BIGINT      NOT NULL DEFAULT 0, -- likes - dislikes (для сортировок)
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Защитный уникальный ключ на пару type+id уже есть в reaction_targets.
```

## Запросы

### Получить/создать target_uid для произвольной цели

```sql
INSERT INTO reaction_targets (target_type, target_id)
VALUES ($1, $2)
ON CONFLICT (target_type, target_id) DO UPDATE SET target_id = EXCLUDED.target_id
RETURNING id;
```

### Upsert реакции пользователя (три случая)  
- Был 0→1 (новый лайк), 1→-1 (смена на дизлайк), 1→0 (сняли лайк) и т.д.  
- Важно сразу посчитать дельту для счётчиков.  

```sql
WITH old AS (
  SELECT reaction
  FROM reactions
  WHERE target_uid = $1 AND user_id = $2
),
up AS (
  INSERT INTO reactions (target_uid, user_id, reaction)
  VALUES ($1, $2, $3)                            -- $3 ∈ {-1,0,1}
  ON CONFLICT (target_uid, user_id)
  DO UPDATE SET reaction = EXCLUDED.reaction,
                updated_at = now()
  RETURNING reaction
)
SELECT 
  COALESCE((SELECT reaction FROM old), 0)  AS old_reaction,
  (SELECT reaction FROM up)                AS new_reaction;
```


На приложении по (old_reaction, new_reaction) считаем дельты:

```(0 → 1): likes += 1, score += 1```  
```(0 → -1): dislikes += 1, score -= 1```  
```(1 → 0): likes -= 1, score -= 1```  
```(-1 → 0): dislikes -= 1, score += 1```  
```(1 → -1): likes -= 1, dislikes += 1, score -= 2```  
```(-1 → 1): dislikes -= 1, likes += 1, score += 2```  
```(x → x): ничего.``` 

Применяем дельту к reaction_counters:  

```sql
INSERT INTO reaction_counters (target_uid, likes, dislikes, score, updated_at)
VALUES ($1, $likes_delta, $dislikes_delta, $score_delta, now())
ON CONFLICT (target_uid)
DO UPDATE SET 
  likes    = reaction_counters.likes    + EXCLUDED.likes,
  dislikes = reaction_counters.dislikes + EXCLUDED.dislikes,
  score    = reaction_counters.score    + EXCLUDED.score,
  updated_at = now();
```

Быстрое чтение счётчиков по цели  

```sql
SELECT likes, dislikes, score
FROM reaction_counters
WHERE target_uid = $1;
```

Фоллбэк (если записи ещё нет):  
```sql
SELECT
  SUM(CASE WHEN reaction = 1  THEN 1 ELSE 0 END) AS likes,
  SUM(CASE WHEN reaction = -1 THEN 1 ELSE 0 END) AS dislikes,
  SUM(CASE WHEN reaction = 1  THEN 1
           WHEN reaction = -1 THEN -1 ELSE 0 END) AS score
FROM reactions
WHERE target_uid = $1;
```



### PHP: сервисный слой (PDO)

```php
<?php
class ReactionsService {
    public function __construct(
        private PDO $db,
        private Redis $redis
    ) {}

    /** Получить/создать target_uid */
    public function ensureTarget(string $type, int $id): int {
        $stmt = $this->db->prepare(
            "INSERT INTO reaction_targets (target_type, target_id)
             VALUES (:t,:i)
             ON CONFLICT (target_type, target_id)
             DO UPDATE SET target_id = EXCLUDED.target_id
             RETURNING id"
        );
        $stmt->execute([':t'=>$type, ':i'=>$id]);
        return (int)$stmt->fetchColumn();
    }

    /** Установить реакцию пользователя: -1, 0, 1 */
    public function react(int $targetUid, int $userId, int $new): array {
        if (!in_array($new, [-1,0,1], true)) {
            throw new InvalidArgumentException("reaction must be -1,0,1");
        }

        $this->db->beginTransaction();
        try {
            // 1) upsert реакции и получить старое/новое
            $sql = <<<SQL
            WITH old AS (
              SELECT reaction FROM reactions
              WHERE target_uid = :tu AND user_id = :u
            ),
            up AS (
              INSERT INTO reactions (target_uid, user_id, reaction)
              VALUES (:tu, :u, :r)
              ON CONFLICT (target_uid, user_id)
              DO UPDATE SET reaction = EXCLUDED.reaction, updated_at = now()
              RETURNING reaction
            )
            SELECT COALESCE((SELECT reaction FROM old), 0) AS old_reaction,
                   (SELECT reaction FROM up)               AS new_reaction;
            SQL;
            $st = $this->db->prepare($sql);
            $st->execute([':tu'=>$targetUid, ':u'=>$userId, ':r'=>$new]);
            $row = $st->fetch(PDO::FETCH_ASSOC);
            $old = (int)$row['old_reaction'];
            $new = (int)$row['new_reaction'];

            // 2) посчитать дельты
            [$dl, $dd, $ds] = $this->delta($old, $new);
            if ($dl || $dd || $ds) {
                $st2 = $this->db->prepare(
                    "INSERT INTO reaction_counters (target_uid, likes, dislikes, score, updated_at)
                     VALUES (:tu, :l, :d, :s, now())
                     ON CONFLICT (target_uid) DO UPDATE SET
                       likes = reaction_counters.likes + EXCLUDED.likes,
                       dislikes = reaction_counters.dislikes + EXCLUDED.dislikes,
                       score = reaction_counters.score + EXCLUDED.score,
                       updated_at = now()"
                );
                $st2->execute([':tu'=>$targetUid, ':l'=>$dl, ':d'=>$dd, ':s'=>$ds]);
            }

            $this->db->commit();

            // 3) обновить Redis (best-effort)
            $key = "react:cnt:$targetUid";
            if ($dl || $dd || $ds) {
                // попробуем HINCRBY, но мы храним JSON, покажу простой вариант: заново прочитать из БД и SET
                $cnt = $this->getCountersFromDb($targetUid);
                $this->redis->setex($key, rand(600, 1800), json_encode($cnt));
            }

            return ['old'=>$old, 'new'=>$new];

        } catch (Throwable $e) {
            $this->db->rollBack();
            throw $e;
        }
    }

    /** Получить counters (Redis → DB) */
    public function getCounters(int $targetUid): array {
        $key = "react:cnt:$targetUid";
        $cached = $this->redis->get($key);
        if ($cached) return json_decode($cached, true);

        $cnt = $this->getCountersFromDb($targetUid);
        $this->redis->setex($key, rand(600, 1800), json_encode($cnt));
        return $cnt;
    }

    private function getCountersFromDb(int $targetUid): array {
        $st = $this->db->prepare(
            "SELECT likes, dislikes, score
             FROM reaction_counters WHERE target_uid = :tu"
        );
        $st->execute([':tu'=>$targetUid]);
        $r = $st->fetch(PDO::FETCH_ASSOC);
        if ($r) return array_map('intval', $r);

        // фоллбэк: посчитать по фактам
        $st2 = $this->db->prepare(
            "SELECT
               SUM(CASE WHEN reaction=1  THEN 1 ELSE 0 END) AS likes,
               SUM(CASE WHEN reaction=-1 THEN 1 ELSE 0 END) AS dislikes,
               SUM(CASE WHEN reaction=1  THEN 1
                        WHEN reaction=-1 THEN -1 ELSE 0 END) AS score
             FROM reactions WHERE target_uid = :tu"
        );
        $st2->execute([':tu'=>$targetUid]);
        $r2 = $st2->fetch(PDO::FETCH_ASSOC) ?: ['likes'=>0,'dislikes'=>0,'score'=>0];

        // инициализируем counters
        $ins = $this->db->prepare(
            "INSERT INTO reaction_counters (target_uid, likes, dislikes, score)
             VALUES (:tu,:l,:d,:s)
             ON CONFLICT (target_uid) DO NOTHING"
        );
        $ins->execute([':tu'=>$targetUid, ':l'=>(int)$r2['likes'], ':d'=>(int)$r2['dislikes'], ':s'=>(int)$r2['score']]);

        return array_map('intval', $r2);
    }

    private function delta(int $old, int $new): array {
        // возвращает [likes_delta, dislikes_delta, score_delta]
        if ($old === $new) return [0,0,0];
        return match (true) {
            $old===0 && $new===1   => [ 1, 0, +1],
            $old===0 && $new===-1  => [ 0, 1, -1],
            $old===1 && $new===0   => [-1, 0, -1],
            $old===-1 && $new===0  => [ 0,-1, +1],
            $old===1 && $new===-1  => [-1, 1, -2],
            $old===-1 && $new===1  => [ 1,-1, +2],
            default                => [0,0,0],
        };
    }
}

```