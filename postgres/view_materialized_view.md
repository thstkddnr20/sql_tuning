# View와 Materialized View

View는 쿼리에 이름을 붙여 저장해 둔 것이다. 데이터를 갖지 않고, 조회할 때마다 원본 쿼리가 다시 실행된다.
Materialized View는 그 쿼리의 **결과를 실제 디스크에 저장**해 둔 것이다. 조회는 빠르지만 원본 데이터와 자동으로 동기화되지 않는다.

| 구분 | View | Materialized View |
|---|---|---|
| 저장하는 것 | 쿼리 정의 | 쿼리 실행 결과(데이터) |
| 조회 시점 동작 | 원본 쿼리 재실행 | 저장된 결과 읽기 |
| 데이터 신선도 | 항상 최신 | REFRESH 시점 기준 |

이 세 줄을 직접 확인하는 것이 이 문서의 전부다.

---

## 사전 준비

실습 대상은 **조인 3개 + 집계**가 들어간 무거운 쿼리다.
60만 건의 `order_item`을 훑지만 결과는 192건(4등급 × 48개월)으로 줄어드는, Materialized View가 가장 효과를 보는 형태다.

```sql
CREATE VIEW v_sales_summary AS
SELECT m.grade,
       date_trunc('month', o.ordered_at)::DATE AS month,
       SUM(oi.qty * oi.unit_price)             AS amount
FROM orders o
         JOIN order_item oi ON oi.order_id = o.order_id
         JOIN member     m  ON m.member_id = o.member_id
WHERE o.status IN ('P', 'D', 'C')
GROUP BY 1, 2;

CREATE MATERIALIZED VIEW mv_sales_summary AS
SELECT m.grade,
       date_trunc('month', o.ordered_at)::DATE AS month,
       SUM(oi.qty * oi.unit_price)             AS amount
FROM orders o
         JOIN order_item oi ON oi.order_id = o.order_id
         JOIN member     m  ON m.member_id = o.member_id
WHERE o.status IN ('P', 'D', 'C')
GROUP BY 1, 2;
```

`CREATE VIEW`는 즉시 끝나지만 `CREATE MATERIALIZED VIEW`는 쿼리를 한 번 실행한다. 여기서부터 차이가 보인다.

```
\timing on
```

---

## 실험 1: 무엇을 저장하는가

```sql
SELECT relname,
       relkind,
       pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class
WHERE relname IN ('v_sales_summary', 'mv_sales_summary');
```

```
     relname      | relkind |  size   
------------------+---------+---------
 v_sales_summary  | v       | 0 bytes
 mv_sales_summary | m       | 16 kB
(2 rows)

Time: 3.710 ms
```

- `relkind = 'v'` → View, `'m'` → Materialized View
- View의 크기는 **0**이다. 저장하는 데이터가 없기 때문이다.

View가 저장하는 것이 무엇인지 직접 본다.

```sql
SELECT pg_get_viewdef('v_sales_summary'::regclass, true);
```

```
                            pg_get_viewdef                             
-----------------------------------------------------------------------
  SELECT m.grade,                                                     +
     date_trunc('month'::text, o.ordered_at)::date AS month,          +
     sum(oi.qty * oi.unit_price) AS amount                            +
    FROM orders o                                                     +
      JOIN order_item oi ON oi.order_id = o.order_id                  +
      JOIN member m ON m.member_id = o.member_id                      +
   WHERE o.status = ANY (ARRAY['P'::bpchar, 'D'::bpchar, 'C'::bpchar])+
   GROUP BY m.grade, (date_trunc('month'::text, o.ordered_at)::date);
(1 row)

Time: 1.755 ms
```

**확인 포인트**: View가 저장하는 것은 데이터가 아니라 쿼리 정의다.

---

## 실험 2: 조회할 때 무슨 일이 일어나는가

```sql
EXPLAIN ANALYZE SELECT * FROM v_sales_summary;
```

```
                                                               QUERY PLAN                                                                
-----------------------------------------------------------------------------------------------------------------------------------------
 HashAggregate  (cost=28184.58..35675.56 rows=499399 width=14) (actual time=567.802..570.089 rows=192 loops=1)
   Group Key: m.grade, (date_trunc('month'::text, o.ordered_at))::date
   Batches: 1  Memory Usage: 24609kB
   ->  Hash Join  (cost=7976.16..23190.59 rows=499399 width=12) (actual time=66.149..484.381 rows=510000 loops=1)
         Hash Cond: (o.member_id = m.member_id)
         ->  Hash Join  (cost=6335.16..17732.20 rows=502965 width=18) (actual time=59.105..291.285 rows=510000 loops=1)
               Hash Cond: (oi.order_id = o.order_id)
               ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=10) (actual time=0.011..34.899 rows=600000 loops=1)
               ->  Hash  (cost=4221.00..4221.00 rows=169133 width=16) (actual time=58.938..58.941 rows=170000 loops=1)
                     Buckets: 262144  Batches: 1  Memory Usage: 10017kB
                     ->  Seq Scan on orders o  (cost=0.00..4221.00 rows=169133 width=16) (actual time=0.013..26.232 rows=170000 loops=1)
                           Filter: (status = ANY ('{P,D,C}'::bpchar[]))
                           Rows Removed by Filter: 30000
         ->  Hash  (cost=1016.00..1016.00 rows=50000 width=6) (actual time=6.985..6.986 rows=50000 loops=1)
               Buckets: 65536  Batches: 1  Memory Usage: 2466kB
               ->  Seq Scan on member m  (cost=0.00..1016.00 rows=50000 width=6) (actual time=0.010..3.043 rows=50000 loops=1)
 Planning Time: 0.228 ms
 Execution Time: 570.781 ms
(18 rows)

Time: 571.480 ms
```

```sql
EXPLAIN ANALYZE SELECT * FROM mv_sales_summary;
```

```
                                                  QUERY PLAN                                                   
---------------------------------------------------------------------------------------------------------------
 Seq Scan on mv_sales_summary  (cost=0.00..3.92 rows=192 width=14) (actual time=0.006..0.014 rows=192 loops=1)
 Planning Time: 0.096 ms
 Execution Time: 0.063 ms
(3 rows)

Time: 0.557 ms
```

| 대상 | 실행 시간  | 계획 형태       |
|---|------------|-----------------|
| View | 571.480 ms | 쿼리 실행       |
| Materialized View | 0.557 ms   | 테이블 Seq Scan |

**확인 포인트**

- View의 실행 계획에 `v_sales_summary`라는 이름이 나오는가?
  View는 실행 전에 원본 쿼리로 치환되므로 계획에는 `orders`, `order_item`, `member` 조인이 그대로 드러난다.
- Materialized View는 192건짜리 테이블 하나를 Seq Scan 할 뿐이다.
- 즉 **View는 성능 개선 수단이 아니다.** 복잡한 쿼리를 이름으로 감추는 것이지, 빨라지는 것이 아니다.

---

## 실험 3: 데이터가 바뀌면

Materialized View의 대가는 **원본과 어긋난다는 것**이다.

### Step 1. 원본 데이터 변경

```sql
INSERT INTO orders (member_id, status, ordered_at, total_amount)
VALUES (1, 'C', '2023-12-01 10:00:00', 999000)
RETURNING order_id;

-- 위에서 반환된 order_id 사용
INSERT INTO order_item (order_id, product_id, qty, unit_price)
VALUES (<order_id>, 1, 10, 1000000);
```

### Step 2. 두 쪽을 비교

```sql
SELECT 'view' AS src, amount FROM v_sales_summary
WHERE month = '2023-12-01' AND grade = (SELECT grade FROM member WHERE member_id = 1)
UNION ALL
SELECT 'matview', amount FROM mv_sales_summary
WHERE month = '2023-12-01' AND grade = (SELECT grade FROM member WHERE member_id = 1);
```

```
   src   |  amount   
---------+-----------
 view    | 248502000
 matview | 238502000
(2 rows)

Time: 52.786 ms
```

**확인 포인트**: View는 즉시 반영, Materialized View는 옛날 값 그대로다.
Materialized View는 **저장 시점의 스냅샷**이다.

### Step 3. REFRESH

```sql
REFRESH MATERIALIZED VIEW mv_sales_summary;
```

```
REFRESH MATERIALIZED VIEW
Time: 320.863 ms
```

Step 2의 비교 쿼리를 다시 실행한다.

```
   src   |  amount   
---------+-----------
 view    | 248502000
 matview | 248502000
(2 rows)

Time: 39.237 ms
```

**확인 포인트**

- REFRESH 소요 시간이 실험 2의 View 조회 시간과 비슷한가?
  REFRESH는 결국 **원본 쿼리 전체를 다시 실행**하는 것이다. (PostgreSQL은 부분 갱신을 제공하지 않는다)
- 그래서 이득은 조회 빈도와 갱신 빈도의 비율에서 나온다.
  View는 `쿼리비용 × 조회횟수`, Materialized View는 `쿼리비용 × 갱신횟수 + 작은조회 × 조회횟수`다.
  **조회가 갱신보다 훨씬 잦을 때만** 이득이다.

---

## 전체 정리

| 상황 | 선택 |
|---|---|
| 복잡한 조인/조건을 이름으로 감추고 싶다 | View |
| 항상 최신 데이터가 필요하다 | View |
| 집계 비용이 크고, 조회는 잦지만 갱신은 드물다 | Materialized View |
| 대시보드/통계처럼 약간의 지연이 허용된다 | Materialized View |
| 실시간 정합성이 필요하다 | Materialized View 사용 불가 |

핵심 세 가지:

1. **View는 쿼리 재작성일 뿐이다.** 원본 쿼리와 실행 계획이 같으므로 빨라지지 않는다.
2. **Materialized View는 결과를 저장한 스냅샷이다.** 그래서 빠르고, 그래서 낡는다.
3. **REFRESH는 전체 재계산이다.** 조회 빈도 > 갱신 빈도일 때만 이득이다.

> 더 파고들 거리 — Materialized View는 인덱스를 걸 수 있고(View는 불가),
> `REFRESH`는 조회를 막는 락을 잡기 때문에 운영에서는 UNIQUE 인덱스 + `REFRESH ... CONCURRENTLY`가 필요하다.

---

## 실습 정리

```sql
DROP MATERIALIZED VIEW IF EXISTS mv_sales_summary;
DROP VIEW IF EXISTS v_sales_summary;

DELETE FROM order_item WHERE unit_price = 1000000 AND qty = 10;
DELETE FROM orders WHERE total_amount = 999000 AND ordered_at = '2023-12-01 10:00:00';
```
