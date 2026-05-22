# 복잡한 조인 쿼리 튜닝

## 시나리오 개요

이 시나리오는 PostgreSQL의 `work_mem` 파라미터가 메모리 사용에 미치는 영향을 보여줍니다. `work_mem`은 정렬, 해시 조인, 집계 등의 메모리 집약적 작업에 사용되는 메모리 양을 제어합니다. 값이 너무 낮으면 이러한 작업이 디스크로 스필되어 성능이 저하됩니다.

## 문제 상황

다음 쿼리는 대용량 테이블에서 주문 금액 상위 100명을 조회하는 작업입니다. 이 쿼리는 `ORDER BY`와 `GROUP BY` 작업을 수행하며, 기본 `work_mem` 설정(4MB)에서는 성능이 저하될 수 있습니다.

```sql
-- work_mem 튜닝 전 문제 쿼리
SELECT 
  m.member_id,
  m.name,
  SUM(oi.qty * oi.unit_price) AS total_spent
FROM member m
JOIN orders o ON m.member_id = o.member_id
JOIN order_item oi ON o.order_id = oi.order_id
WHERE o.status = 'C'  -- 완료된 주문만
GROUP BY m.member_id, m.name
ORDER BY total_spent DESC
LIMIT 100;

-- 주문을 완료한 사용자가 주문한 전체 비용이 높은 순서대로 100건을 member_id, name, total_spent로 반환한다. 
```

## 기본
```
 Limit  (cost=23651.64..23651.89 rows=100 width=25) (actual time=242.139..242.150 rows=100 loops=1)
   Buffers: shared hit=5809
   ->  Sort  (cost=23651.64..23776.64 rows=50000 width=25) (actual time=242.137..242.144 rows=100 loops=1)
         Sort Key: (sum((oi.qty * oi.unit_price))) DESC
         Sort Method: top-N heapsort  Memory: 37kB
         Buffers: shared hit=5809
         ->  HashAggregate  (cost=21240.68..21740.68 rows=50000 width=25) (actual time=237.573..239.822 rows=25000 loops=1)
               Group Key: m.member_id
               Batches: 1  Memory Usage: 4113kB
               Buffers: shared hit=5809
               ->  Hash Join  (cost=6865.09..19037.71 rows=293729 width=23) (actual time=26.919..193.493 rows=300000 loops=1)
                     Hash Cond: (o.member_id = m.member_id)
                     Buffers: shared hit=5809
                     ->  Hash Join  (cost=5224.09..16621.12 rows=295438 width=10) (actual time=20.398..137.764 rows=300000 loops=1)
                           Hash Cond: (oi.order_id = o.order_id)
                           Buffers: shared hit=5293
                           ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=10) (actual time=0.007..21.662 rows=600000 loops=1)
                                 Buffers: shared hit=3822
                           ->  Hash  (cost=3971.00..3971.00 rows=100247 width=8) (actual time=20.197..20.197 rows=100000 loops=1)
                                 Buckets: 131072  Batches: 1  Memory Usage: 4931kB
                                 Buffers: shared hit=1471
                                 ->  Seq Scan on orders o  (cost=0.00..3971.00 rows=100247 width=8) (actual time=0.008..10.559 rows=100000 loops=1)
                                       Filter: (status = 'C'::bpchar)
                                       Rows Removed by Filter: 100000
                                       Buffers: shared hit=1471
                     ->  Hash  (cost=1016.00..1016.00 rows=50000 width=17) (actual time=6.480..6.481 rows=50000 loops=1)
                           Buckets: 65536  Batches: 1  Memory Usage: 2905kB
                           Buffers: shared hit=516
                           ->  Seq Scan on member m  (cost=0.00..1016.00 rows=50000 width=17) (actual time=0.010..2.665 rows=50000 loops=1)
                                 Buffers: shared hit=516
 Planning:
   Buffers: shared hit=16
 Planning Time: 0.295 ms
 Execution Time: 242.491 ms

```

실행 계획 분석  
```
1. Seq Scan orders → status='C' 필터 → 100,000건
2. 1번 결과로 Hash 테이블 구성 (key=order_id)
3. Seq Scan order_item 600,000건 → 2번 해시 탐색 → Hash Join
   결과 300,000건 (order_id + member_id + qty + unit_price)
4. Seq Scan member 50,000건 → Hash 테이블 구성 (key=member_id)
5. 3번 결과와 Hash Join → 300,000건 (member 정보 붙음)
6. HashAggregate
   → member_id로 그룹핑
   → SUM(qty * unit_price) 동시 집계  ← 7번이 여기 포함
   → 300,000건 → 25,000건
7. Sort (top-N heapsort) → 상위 100건만 유지
8. Limit 100 반환
```

## Step 1. Seq Scan on orders o 없애기 위해 index 생성
`create index idx_orders_status_include_member_id_order_id on orders(status) include (member_id, order_id);`

```
 Limit  (cost=21862.19..21862.44 rows=100 width=25) (actual time=227.439..227.450 rows=100 loops=1)
   Buffers: shared hit=4725
   ->  Sort  (cost=21862.19..21987.19 rows=50000 width=25) (actual time=227.437..227.443 rows=100 loops=1)
         Sort Key: (sum((oi.qty * oi.unit_price))) DESC
         Sort Method: top-N heapsort  Memory: 37kB
         Buffers: shared hit=4725
         ->  HashAggregate  (cost=19451.22..19951.22 rows=50000 width=25) (actual time=223.098..225.241 rows=25000 loops=1)
               Group Key: m.member_id
               Batches: 1  Memory Usage: 4113kB
               Buffers: shared hit=4725
               ->  Hash Join  (cost=5075.63..17248.25 rows=293729 width=23) (actual time=24.136..182.874 rows=300000 loops=1)
                     Hash Cond: (o.member_id = m.member_id)
                     Buffers: shared hit=4725
                     ->  Hash Join  (cost=3434.63..14831.66 rows=295438 width=10) (actual time=15.590..129.295 rows=300000 loops=1)
                           Hash Cond: (oi.order_id = o.order_id)
                           Buffers: shared hit=4209
                           ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=10) (actual time=0.004..25.936 rows=600000 loops=1)
                                 Buffers: shared hit=3822
                           ->  Hash  (cost=2181.54..2181.54 rows=100247 width=8) (actual time=15.449..15.450 rows=100000 loops=1)
                                 Buckets: 131072  Batches: 1  Memory Usage: 4931kB
                                 Buffers: shared hit=387
                                 ->  Index Only Scan using idx_orders_status_include_member_id_order_id on orders o  (cost=0.42..2181.54 rows=100247 width=8) (actual time=0.040..7.957 rows=100000 loops=1)
                                       Index Cond: (status = 'C'::bpchar)
                                       Heap Fetches: 0
                                       Buffers: shared hit=387
                     ->  Hash  (cost=1016.00..1016.00 rows=50000 width=17) (actual time=8.349..8.350 rows=50000 loops=1)
                           Buckets: 65536  Batches: 1  Memory Usage: 2905kB
                           Buffers: shared hit=516
                           ->  Seq Scan on member m  (cost=0.00..1016.00 rows=50000 width=17) (actual time=0.016..3.585 rows=50000 loops=1)
                                 Buffers: shared hit=516
 Planning:
   Buffers: shared hit=16
 Planning Time: 1.052 ms
 Execution Time: 228.111 ms
```

## Step 2. 조회 구조 변경
```sql
WITH filtered_orders AS (
    SELECT order_id, member_id
    FROM orders
    WHERE status = 'C'
),
item_sum AS (
    SELECT fo.member_id, SUM(oi.qty * oi.unit_price) AS total
    FROM order_item oi
    JOIN filtered_orders fo ON oi.order_id = fo.order_id
    GROUP BY fo.member_id
)
SELECT m.member_id, m.name, s.total AS grand_total
FROM item_sum s
JOIN member m ON s.member_id = m.member_id
ORDER BY grand_total DESC
LIMIT 100;
```

```
 Limit  (cost=21527.57..21527.82 rows=100 width=25) (actual time=157.743..157.753 rows=100 loops=1)
   Buffers: shared hit=4725
   ->  Sort  (cost=21527.57..21645.39 rows=47128 width=25) (actual time=157.741..157.747 rows=100 loops=1)
         Sort Key: s.total DESC
         Sort Method: top-N heapsort  Memory: 36kB
         Buffers: shared hit=4725
         ->  Hash Join  (cost=18579.11..19726.37 rows=47128 width=25) (actual time=148.734..155.575 rows=25000 loops=1)
               Hash Cond: (m.member_id = s.member_id)
               Buffers: shared hit=4725
               ->  Seq Scan on member m  (cost=0.00..1016.00 rows=50000 width=17) (actual time=0.009..1.785 rows=50000 loops=1)
                     Buffers: shared hit=516
               ->  Hash  (cost=17990.01..17990.01 rows=47128 width=12) (actual time=148.671..148.674 rows=25000 loops=1)
                     Buckets: 65536  Batches: 1  Memory Usage: 1587kB
                     Buffers: shared hit=4209
                     ->  Subquery Scan on s  (cost=17047.45..17990.01 rows=47128 width=12) (actual time=143.368..146.868 rows=25000 loops=1)
                           Buffers: shared hit=4209
                           ->  HashAggregate  (cost=17047.45..17518.73 rows=47128 width=12) (actual time=143.367..145.684 rows=25000 loops=1)
                                 Group Key: orders.member_id
                                 Batches: 1  Memory Usage: 3345kB
                                 Buffers: shared hit=4209
                                 ->  Hash Join  (cost=3434.63..14831.66 rows=295438 width=10) (actual time=18.762..111.981 rows=300000 loops=1)
                                       Hash Cond: (oi.order_id = orders.order_id)
                                       Buffers: shared hit=4209
                                       ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=10) (actual time=0.005..20.810 rows=600000 loops=1)
                                             Buffers: shared hit=3822
                                       ->  Hash  (cost=2181.54..2181.54 rows=100247 width=8) (actual time=18.647..18.648 rows=100000 loops=1)
                                             Buckets: 131072  Batches: 1  Memory Usage: 4931kB
                                             Buffers: shared hit=387
                                             ->  Index Only Scan using idx_orders_status_include_member_id_order_id on orders  (cost=0.42..2181.54 rows=100247 width=8) (actual time=0.036..8.949 rows=100000 loops=1)
                                                   Index Cond: (status = 'C'::bpchar)
                                                   Heap Fetches: 0
                                                   Buffers: shared hit=387
 Planning:
   Buffers: shared hit=8
 Planning Time: 0.345 ms
 Execution Time: 157.969 ms
```

실행 계획 분석  
```
1. orders 테이블에서 status='C'인 데이터의 order_id, member_id를 filtered_orders CTE로 생성
2. filtered_orders CTE로 해시 테이블 생성
3. order_item을 Seq Scan하여 행을 하나씩 가져오면서 filtered_orders 해시 조인
4. member_id로 group by를 하기 위해 HashAggregate
5. 구체화된 item_sum CTE를 읽기 위해 subquery scan 발생
6. item_sum CTE로 해시 테이블 생성
7. member를 Seq Scan하여 item_sum과 해시 조인
8. item_sum의 total 값으로 내림차순 정렬
9. 100개만 가져옴
```

## Step 3. 서브쿼리로 해결
```sql
SELECT m.member_id, m.name, t.grand_total
FROM (
    SELECT o.member_id, SUM(oi.qty * oi.unit_price) AS grand_total
    FROM orders o
    JOIN order_item oi ON o.order_id = oi.order_id
    WHERE o.status = 'C'
    GROUP BY o.member_id
    ORDER BY grand_total DESC
    LIMIT 100
) t
JOIN member m ON t.member_id = m.member_id
ORDER BY t.grand_total DESC;
```

```
 Nested Loop  (cost=19320.22..19444.33 rows=100 width=25) (actual time=148.982..149.111 rows=100 loops=1)
   Buffers: shared hit=4410
   ->  Limit  (cost=19319.93..19320.18 rows=100 width=12) (actual time=148.961..148.970 rows=100 loops=1)
         Buffers: shared hit=4209
         ->  Sort  (cost=19319.93..19437.75 rows=47128 width=12) (actual time=148.959..148.964 rows=100 loops=1)
               Sort Key: (sum((oi.qty * oi.unit_price))) DESC
               Sort Method: top-N heapsort  Memory: 31kB
               Buffers: shared hit=4209
               ->  HashAggregate  (cost=17047.45..17518.73 rows=47128 width=12) (actual time=144.504..147.383 rows=25000 loops=1)
                     Group Key: o.member_id
                     Batches: 1  Memory Usage: 3345kB
                     Buffers: shared hit=4209
                     ->  Hash Join  (cost=3434.63..14831.66 rows=295438 width=10) (actual time=19.846..112.385 rows=300000 loops=1)
                           Hash Cond: (oi.order_id = o.order_id)
                           Buffers: shared hit=4209
                           ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=10) (actual time=0.010..20.739 rows=600000 loops=1)
                                 Buffers: shared hit=3822
                           ->  Hash  (cost=2181.54..2181.54 rows=100247 width=8) (actual time=19.725..19.725 rows=100000 loops=1)
                                 Buckets: 131072  Batches: 1  Memory Usage: 4931kB
                                 Buffers: shared hit=387
                                 ->  Index Only Scan using idx_orders_status_include_member_id_order_id on orders o  (cost=0.42..2181.54 rows=100247 width=8) (actual time=0.037..9.510 rows=100000 loops=1)
                                       Index Cond: (status = 'C'::bpchar)
                                       Heap Fetches: 0
                                       Buffers: shared hit=387
   ->  Index Only Scan using idx_member_member_id_include_name on member m  (cost=0.29..1.23 rows=1 width=17) (actual time=0.001..0.001 rows=1 loops=100)
         Index Cond: (member_id = o.member_id)
         Heap Fetches: 0
         Buffers: shared hit=201
 Planning:
   Buffers: shared hit=16
 Planning Time: 0.398 ms
 Execution Time: 149.354 ms
```
