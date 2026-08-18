# shared_buffers와 캐시 적중률(Buffer Cache Hit Ratio)

`work_mem`이 **쿼리 처리 중간 결과**를 담는 세션성 메모리였다면, `shared_buffers`는 디스크의 데이터
page(기본 8KB)를 통째로 올려두는 **서버 전역 공용 캐시**다. 기동할 때 한 번 잡고 끝까지 유지한다.

쿼리가 필요한 page를 `shared_buffers`에서 찾으면(**hit**) 디스크로 내려가지 않는다.
없으면(**read/miss**) 디스크(정확히는 OS)를 거쳐 page를 올린 뒤 처리한다.
그래서 목표는 **hit 비율을 높여 물리 I/O를 줄이는 것** — 큰 방향은 맞다. 다만 여기서 세 가지를 직접 확인한다.

1. `EXPLAIN (ANALYZE, BUFFERS)`의 `shared hit` / `shared read`가 각각 무엇을 뜻하는가 (실험 1)
2. 서버 전역 hit ratio를 `pg_stat_database`로 계산하고, **read=miss가 곧 물리 디스크 접근은 아니라는 것**(이중 캐시) (실험 2)
3. `shared_buffers`에 지금 **어떤 테이블의 page가 몇 개** 올라와 있는지 실제로 들여다보기 (실험 3)
4. hit ratio는 결과 지표일 뿐, 본질은 **건드리는 buffer 수 자체를 줄이는 것**임을 인덱스로 확인 (실험 4)

세 번째와 네 번째가 핵심이다. "shared_buffers를 키워라"가 아니라 "**필요한 page를 적게, 그리고 재사용되게**"가 방향이다.

---

## 사전 준비

### 접속

```bash
docker compose -f docker-compose-postgres.yml up -d
docker exec -it sql-tuning-postgres psql -U tuning -d tuning
```

### 현재 설정 확인

```sql
SHOW shared_buffers;   -- 이 환경은 256MB (docker-compose-postgres.yml에서 지정)
SHOW effective_cache_size;
```

```
 shared_buffers 
----------------
 256MB
(1 row)

 effective_cache_size 
----------------------
 4GB
(1 row)
```

이 실습 환경은 `shared_buffers = 256MB`로 시작한다. 데이터 총량(아래 실험 3에서 확인)이 이보다 작다면
**워밍업 이후에는 DB 전체가 캐시에 들어가** hit ratio가 사실상 100%에 가까워진다. 그 상태를 먼저 관찰하고,
캐시보다 데이터가 클 때 무슨 일이 생기는지는 실험 5(선택)에서 `shared_buffers`를 줄여 재현한다.

### 확장 설치

버퍼 내부를 들여다보려면 `pg_buffercache`, 캐시를 의도적으로 데우려면 `pg_prewarm`이 필요하다.

```sql
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
```

### 관찰 도구 정리

| 도구 | 관찰 범위 | 보는 것 |
|---|---|---|
| `EXPLAIN (ANALYZE, BUFFERS)` | 쿼리 1건 | 이 쿼리가 `shared hit` / `shared read`를 각각 몇 block 했나 |
| `pg_stat_database` | DB 전역 누적 | `blks_hit` / `blks_read` → 전역 hit ratio |
| `pg_statio_user_tables` / `_indexes` | 테이블·인덱스별 누적 | 어느 객체가 캐시를 못 타는가 |
| `pg_buffercache` | 지금 이 순간 | 버퍼에 실제로 올라와 있는 page의 정체 |

```sql
\timing on
```

---

## 실험 1: EXPLAIN BUFFERS로 hit과 read 구분하기

같은 쿼리를 **캐시가 빈 상태(cold)** 와 **데워진 상태(warm)** 에서 각각 실행해 `shared hit` / `shared read`가
어떻게 뒤바뀌는지 본다.

### Step 1. 캐시 비우기 (cold 상태 만들기)

`shared_buffers`는 서버 재기동으로 비워진다. (OS page cache는 남아 있을 수 있다 — 이 점이 Step 3의 관찰 포인트다.)

```bash
docker restart sql-tuning-postgres
```

재접속 후:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE status = 'C';
```

```
---------------------------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..3971.00 rows=100087 width=22) (actual time=0.274..20.023 rows=100000 loops=1)
   Filter: (status = 'C'::bpchar)
   Rows Removed by Filter: 100000
   Buffers: shared read=1471
 Planning:
   Buffers: shared hit=81 read=24
 Planning Time: 2.958 ms
 Execution Time: 22.342 ms
(8 rows)
```

### Step 2. 같은 쿼리 재실행 (warm 상태)

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE status = 'C';
```

```
--------------------------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..3971.00 rows=100087 width=22) (actual time=0.009..9.627 rows=100000 loops=1)
   Filter: (status = 'C'::bpchar)
   Rows Removed by Filter: 100000
   Buffers: shared hit=1471
 Planning Time: 0.053 ms
 Execution Time: 11.908 ms
(6 rows)
```

### Step 3. 비교

| 실행 | shared hit | shared read | Execution Time |
|---|---|---|---|
| 1회차 (cold) | 0 | 1,471 | 22.3 ms |
| 2회차 (warm) | 1,471 | 0 | 11.9 ms |

**확인 포인트**

- `shared read`는 "그 page가 `shared_buffers`에 **없어서** 새로 올렸다"는 뜻이다.
  1회차에서 read로 잡혔던 block들이 2회차에는 대부분 `shared hit`으로 바뀌어야 한다. — page가 캐시에 눌러앉았기 때문이다.
- `hit + read`의 합(= 접근한 총 block 수)은 두 번 다 비슷해야 정상이다. **바뀌는 건 hit/read의 비율이지 총량이 아니다.**
  총량을 줄이는 건 실험 4에서 인덱스가 한다.
- 주의: 여기서 `read`라고 해서 반드시 **물리 디스크**까지 갔다는 보장은 없다. 재기동은 `shared_buffers`만 비웠고
  OS page cache에는 그 page가 남아 있을 수 있어, 실제로는 메모리에서 읽혔을 수 있다. 이 이중 구조를 실험 2에서 짚는다.

---

## 실험 2: 전역 hit ratio 계산과 "이중 캐시"

`pg_stat_database`는 DB 단위로 `blks_hit`(shared_buffers에서 찾은 수)과 `blks_read`(그 밖에서 읽어야 했던 수)를
누적한다. 이걸로 서버 전체 hit ratio를 낸다.

### Step 1. 통계 초기화 후 워크로드 실행

```sql
SELECT pg_stat_reset();

-- 몇 개의 쿼리를 돌려 부하를 준다
SELECT count(*) FROM order_item;
SELECT * FROM orders WHERE status = 'C';
SELECT o.order_id, m.name
  FROM orders o JOIN member m ON m.member_id = o.member_id
 WHERE o.status = 'X';
```

### Step 2. hit ratio 조회

```sql
SELECT
  datname,
  blks_hit,
  blks_read,
  round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS hit_ratio_pct
FROM pg_stat_database
WHERE datname = 'tuning';
```

```
 datname | blks_hit | blks_read | hit_ratio_pct 
---------+----------+-----------+---------------
 tuning  |     1762 |      4424 |         28.48
```

### Step 3. 같은 워크로드 한 번 더 → 다시 조회

```sql
SELECT pg_stat_reset();
-- Step 1의 쿼리들을 다시 실행
-- 그리고 Step 2 조회를 반복
```

```
 datname | blks_hit | blks_read | hit_ratio_pct 
---------+----------+-----------+---------------
 tuning  |     3822 |         0 |        100.00
```

| 구분 | blks_hit | blks_read | hit_ratio_pct |
|---|---|---|---|
| 1회차 (reset 직후) | 1,762 | 4,424 | 28.48 |
| 2회차 (데워진 뒤) | 3,822 | 0 | 100.00 |

**확인 포인트**

- 2회차 hit ratio가 1회차보다 높아야 한다. 첫 실행에서 올린 page가 캐시에 남아 두 번째엔 hit으로 잡히기 때문이다.
- **`blks_read`가 곧 "물리 디스크 읽기"는 아니다.** PostgreSQL은 `shared_buffers` 밖의 읽기를 전부 `blks_read`로 세는데,
  그 page가 실제로는 **OS page cache**에 있어 메모리에서 왔을 수 있다. 즉 이 지표는 "shared_buffers를 빗나간 비율"이지
  "물리 I/O 비율"이 아니다. 진짜 물리 읽기는 `pg_stat_io`(PG16+)나 `EXPLAIN (ANALYZE, BUFFERS)`의
  `I/O Timings`(`track_io_timing = on` 필요)로 봐야 한다.
- 그래서 "hit ratio 99%"라는 숫자 하나로 안심하면 안 된다. 이 이중 캐시 때문에 `shared_buffers`를 RAM 전체로
  키운다고 좋아지지 않는다 — OS 캐시와 **같은 page를 두 번 들고 있는**(double buffering) 낭비가 생긴다.
  통상 권장이 RAM의 25% 안팎인 이유다.

---

## 실험 3: pg_buffercache로 버퍼 속을 직접 들여다보기

hit ratio는 "결과 숫자"다. 실제로 캐시 안에 **무엇이** 들어있는지 봐야 감이 온다.

### Step 1. 버퍼 총량과 사용 현황

```sql
SHOW shared_buffers;

-- shared_buffers를 8KB page 개수로 환산하면 총 버퍼 수
SELECT count(*) AS total_buffers,
       count(*) FILTER (WHERE relfilenode IS NOT NULL) AS used_buffers
FROM pg_buffercache;
```

```
-- 256MB / 8KB = 32,768개가 총 버퍼 수여야 한다

 total_buffers | used_buffers 
---------------+--------------
         32768 |         6210
```

### Step 2. 어떤 테이블이 버퍼를 얼마나 점유하고 있나

```sql
SELECT
  c.relname,
  count(*)                              AS buffers,
  pg_size_pretty(count(*) * 8 * 1024)   AS cached_size,
  pg_size_pretty(pg_table_size(c.oid))  AS table_size
FROM pg_buffercache b
JOIN pg_class c ON c.relfilenode = pg_relation_filenode(b.relfilenode)
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
GROUP BY c.relname, c.oid
ORDER BY buffers DESC;
```

```
                    relname                     | buffers | cached_size | table_size 
------------------------------------------------+---------+-------------+------------
 order_item                                     |    3822 | 30 MB       | 30 MB
 orders                                         |    1472 | 12 MB       | 12 MB
 member                                         |     517 | 4136 kB     | 4160 kB
 idx_orders_status_include_member_id_order_id   |      43 | 344 kB      | 6184 kB
 idx_orders_member_id                           |       6 | 48 kB       | 2432 kB
 idx_member_member_id_cinlude_name              |       4 | 32 kB       | 1992 kB
 orders_pkey                                    |       1 | 8192 bytes  | 4408 kB
 idx_order_item_order_id_include_qty_unit_price |       1 | 8192 bytes  | 18 MB
 order_item_pkey                                |       1 | 8192 bytes  | 13 MB
 member_pkey                                    |       1 | 8192 bytes  | 1112 kB
```

### Step 3. usagecount — 무엇이 "자주 쓰여" 살아남는가

PostgreSQL은 clock-sweep 방식으로, 접근될 때마다 `usagecount`(최대 5)를 올리고 자리가 필요하면 0인 것부터 내보낸다.

```sql
SELECT usagecount, count(*) AS buffers
FROM pg_buffercache
WHERE relfilenode IS NOT NULL
GROUP BY usagecount
ORDER BY usagecount;
```

```
 usagecount | buffers 
------------+---------
          1 |      57
          2 |    4419
          3 |      20
          4 |    1482
          5 |     249
```

**확인 포인트**

- Step 2에서 `cached_size`가 `table_size`와 같으면 그 테이블은 **통째로 캐시에 올라와 있다.** 이 환경처럼
  DB가 `shared_buffers`보다 작으면 대부분의 테이블이 이렇게 나온다 → 그래서 워밍업 후 hit ratio가 100%에 수렴한다.
- 방금 실험 1·2에서 건드린 `orders`, `order_item`이 상위에 올라와 있는지 본다. **접근한 테이블이 곧 캐시를 차지한다.**
- `usagecount`가 높은(4~5) 버퍼는 자주 재사용되는 뜨거운 page다. 자리 경쟁이 벌어질 때 마지막까지 살아남는다.
  지금은 자리가 남아돌아 0짜리도 많겠지만, 실험 5에서 캐시를 좁히면 이 분포가 어떻게 달라지는지 다시 본다.

---

## 실험 4: hit ratio를 높이는 진짜 방법 — buffer 요구량 자체를 줄이기

`shared_buffers`를 키우는 것보다 훨씬 효과가 큰 건 **애초에 적은 page만 건드리는 것**이다.
같은 결과를 내면서 seq scan과 index scan이 각각 몇 buffer를 만지는지 비교한다.

### Step 1. 인덱스 없이 — 전체 스캔

`order_item`에는 PK(`order_item_id`) 외 인덱스가 없다. `product_id`로 거르면 전체를 훑는다.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_item WHERE product_id = 5000;
```

```
-- Seq Scan, Buffers: shared hit=??? (order_item 전체 ≈ 3822 block)

------------------------------------------------------------------------------------------------------------
 Seq Scan on order_item  (cost=0.00..11322.00 rows=60 width=22) (actual time=0.085..18.153 rows=60 loops=1)
   Filter: (product_id = 5000)
   Rows Removed by Filter: 599940
   Buffers: shared hit=3822
 Planning:
   Buffers: shared hit=9 dirtied=1
 Planning Time: 0.089 ms
 Execution Time: 18.173 ms
(8 rows)
```

### Step 2. 인덱스 추가 후 — 필요한 page만

```sql
CREATE INDEX idx_order_item_product ON order_item(product_id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_item WHERE product_id = 5000;
```

```
-- Index Scan, Buffers: shared hit=??? (수십 block 이하로 급감)

---------------------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on order_item  (cost=4.89..223.09 rows=60 width=22) (actual time=0.040..0.092 rows=60 loops=1)
   Recheck Cond: (product_id = 5000)
   Heap Blocks: exact=60
   Buffers: shared hit=60 read=3
   ->  Bitmap Index Scan on idx_order_item_product  (cost=0.00..4.88 rows=60 width=0) (actual time=0.033..0.033 rows=60 loops=1)
         Index Cond: (product_id = 5000)
         Buffers: shared read=3
 Planning:
   Buffers: shared hit=16 read=1
 Planning Time: 0.188 ms
 Execution Time: 0.127 ms
(11 rows)
```

### Step 3. 비교

| 접근 방식 | 계획 | 건드린 buffer 수 (hit+read) | Execution Time |
|---|---|---|---|
| 인덱스 없음 | Seq Scan | 3,822 (hit 3,822) | 18.2 ms |
| 인덱스 있음 | Bitmap Heap Scan | 63 (hit 60 / read 3) | 0.13 ms |

**확인 포인트**

- 결과 행 수(60건)는 같은데 **만지는 buffer 수가 3,822 → 63으로 약 60배 줄었다.** 실행 시간은 18.2ms → 0.13ms로 100배 이상 빨라졌다.
  이것이 hit ratio를 올리는 가장 확실한 방법이다. seq scan은 매번 테이블 전체 page를 캐시에 요구하고 다른 뜨거운 page를 밀어낼 수 있지만, index scan은 몇 page만 만진다.
- 계획은 순수 `Index Scan`이 아니라 **`Bitmap Heap Scan`** 으로 나왔다. 맞는 60건이 서로 다른 60개 heap page에 흩어져 있어(`Heap Blocks: exact=60`),
  플래너가 인덱스로 대상 page 목록을 먼저 모은 뒤 heap을 한 번에 훑는 방식을 골랐다. 인덱스 자체 page(`shared read=3`)만 캐시에 없어 읽었을 뿐, heap 60 page는 이미 캐시에 있어 hit이었다.
- 즉 "캐시 적중률을 올린다"는 목표의 실체는 대개 "**불필요한 full scan을 없애 buffer 수요를 줄인다**"로 귀결된다.
  `shared_buffers`를 키우는 것은 그 다음 문제다.
- 실험이 끝나면 인덱스를 지워 다른 실습에 영향이 없게 한다: `DROP INDEX idx_order_item_product;`

---

## 실험 5 (선택): 캐시보다 데이터가 클 때 — eviction 관찰

이 환경은 DB가 `shared_buffers`(256MB)보다 작아 eviction이 잘 안 일어난다. 캐시를 일부러 좁혀 재현한다.

### Step 1. shared_buffers를 줄여서 재기동

`docker-compose-postgres.yml`의 command에서 값을 줄인다.

```yaml
      -c shared_buffers=16MB
```

```bash
docker compose -f docker-compose-postgres.yml up -d
```

> 참고: `shared_buffers`는 세션에서 `SET`으로 못 바꾼다. 서버 재기동 파라미터라 compose를 고쳐 다시 띄워야 한다.
> 실습이 끝나면 반드시 256MB로 되돌린다.

### Step 2. 캐시보다 큰 테이블을 반복 스캔

`order_item`(≈30MB)은 이제 16MB 캐시에 다 못 들어간다.

```sql
SELECT pg_stat_reset();

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM order_item;
-- 곧바로 한 번 더
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM order_item;

SELECT blks_hit, blks_read,
       round(100.0*blks_hit/nullif(blks_hit+blks_read,0),2) AS hit_ratio_pct
FROM pg_stat_database WHERE datname='tuning';
```

```
------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=11322.00..11322.01 rows=1 width=8) (actual time=41.196..41.197 rows=1 loops=1)
   Buffers: shared read=3822
   ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=0) (actual time=0.012..25.169 rows=600000 loops=1)
         Buffers: shared read=3822
 Planning:
   Buffers: shared hit=77 read=21
 Planning Time: 0.458 ms
 Execution Time: 41.266 ms
(8 rows)

------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=11322.00..11322.01 rows=1 width=8) (actual time=39.171..39.172 rows=1 loops=1)
   Buffers: shared hit=32 read=3790
   ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=0) (actual time=0.032..23.544 rows=600000 loops=1)
         Buffers: shared hit=32 read=3790
 Planning Time: 0.050 ms
 Execution Time: 39.193 ms
(6 rows)

 blks_hit | blks_read | hit_ratio_pct 
----------+-----------+---------------
      317 |      7661 |          3.97
```

### Step 3. 관찰

**확인 포인트**

- 실험 1과 달리, 두 번째 스캔에서도 `shared read`가 사라지지 않았다. 2회차가 `hit=32 read=3790` — 3,822 block 중
  겨우 32개만 캐시에서 찾았다. 테이블(30MB)이 캐시(16MB)보다 커서 **앞부분을 읽는 동안 뒷부분이 밀려나고, 다음 바퀴엔 그 앞부분이 또 없다.**
  전역 hit ratio도 3.97%에 그친다.
- 여기서 `hit=32`라는 숫자가 결정적이다. 32 block × 8KB = **정확히 256KB**, PostgreSQL이 큰 seq scan에 쓰는 **링 버퍼(ring buffer)의 크기**다.
  `shared_buffers`의 1/4보다 큰 테이블을 스캔할 때 PostgreSQL은 캐시 전체를 쓰지 않고 이 작은 링만 재사용한다 — 큰 스캔 한 방이
  다른 뜨거운 page를 전부 몰아내지 못하게 막는 설계다. 그래서 반복해도 링 크기(32 block)만큼만 재사용되고 나머지는 매번 다시 read다.
- 결론: **working set(자주 쓰는 데이터 집합)이 `shared_buffers`에 들어가느냐**가 hit ratio를 가른다.
  들어가면 실험 1처럼 warm에서 100%, 안 들어가면 아무리 반복해도 read가 남는다.
- 실험 후 `shared_buffers=256MB`로 되돌려 재기동한다.

---

## 전체 정리

| 관찰 대상 | 어디서 보나 | 신호 |
|---|---|---|
| 쿼리 1건의 캐시 사용 | `EXPLAIN (ANALYZE, BUFFERS)` | `Buffers: shared hit=N read=M` |
| DB 전역 hit ratio | `pg_stat_database` | `blks_hit / (blks_hit+blks_read)` |
| 테이블·인덱스별 | `pg_statio_user_tables` | `heap_blks_hit / heap_blks_read` |
| 버퍼 내용 실물 | `pg_buffercache` | 어느 relation이 몇 buffer 점유 |
| 진짜 물리 I/O | `pg_stat_io`, `track_io_timing` | reads/writes, I/O Timings |

핵심 네 가지:

1. **`shared hit`은 캐시에서 찾음, `shared read`는 캐시에 없어 새로 올림.** 같은 쿼리를 두 번 돌리면
   read가 hit으로 바뀐다. 바뀌는 건 비율이지 총 block 수가 아니다.
2. **`blks_read`(miss)가 곧 물리 디스크 읽기는 아니다.** `shared_buffers` 아래에 OS page cache가 한 겹 더 있다.
   그래서 `shared_buffers`를 무작정 키우면 double buffering으로 낭비다 (권장: RAM의 25% 안팎).
3. **hit ratio는 결과 지표다.** 올리는 실체적 방법은 캐시를 키우는 게 아니라, 인덱스로 **건드리는 buffer 수 자체를 줄여**
   working set을 `shared_buffers` 안에 들어오게 만드는 것이다 (실험 4).
4. **working set이 캐시보다 크면** 반복해도 read가 남고, 큰 seq scan은 링 버퍼 때문에 애초에 캐시를 다 채우지도 않는다 (실험 5).

---

## 실습 정리

```sql
-- 실험 4에서 만든 인덱스 제거
DROP INDEX IF EXISTS idx_order_item_product;

-- 통계 초기화
SELECT pg_stat_reset();
```

- 실험 5에서 `shared_buffers`를 줄였다면 `docker-compose-postgres.yml`을 **256MB로 되돌리고** 재기동한다.
- `pg_buffercache` / `pg_prewarm` 확장은 남겨둬도 무방하다 (조회용).
