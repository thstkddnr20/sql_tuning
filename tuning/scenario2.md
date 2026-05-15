# orders 테이블 기존 인덱스에 컬럼 추가하여 성능 개선 2
시나리오 1번에서는 index 탐색 범위가 너무 컸기 때문에 튜닝 효과가 미미했다.
이번에는 index 탐색 범위를 좁혀 기존 인덱스에 컬럼 추가하는 것으로 성능 개선 효과를 확인해보겠다.

## 필요한 쿼리
`SELECT * FROM orders WHERE status = 'X' AND ordered_at >= '2023-12-01';`
status가 C인 orders 데이터는 10만건이지만 X인 데이터는 1만건이므로 index 탐색 범위가 감소한다.
또한 ordered_at을 2023-01-01에서 2023-12-01로 변경하여 조건에 맞는 데이터가 더 적어지도록 하였다.

## Step 1. [status + member_id]
```---------------------------------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on orders  (cost=138.72..1758.22 rows=201 width=22) (actual time=1.171..3.935 rows=213 loops=1)
Recheck Cond: (status = 'X'::bpchar)
Filter: (ordered_at >= '2023-12-01 00:00:00'::timestamp without time zone)
Rows Removed by Filter: 9787
Heap Blocks: exact=1471
->  Bitmap Index Scan on idx_orders_status_member_id  (cost=0.00..138.67 rows=9900 width=0) (actual time=0.855..0.857 rows=10000 loops=1)
Index Cond: (status = 'X'::bpchar)
Planning Time: 0.111 ms
Execution Time: 3.976 ms
(9 rows)
```

Heap Blocks 1471개 탐색

## Step 2. [status + member_id + ordered_at]
```-----------------------------------------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on orders  (cost=255.47..811.25 rows=201 width=22) (actual time=1.034..1.594 rows=213 loops=1)
Recheck Cond: ((status = 'X'::bpchar) AND (ordered_at >= '2023-12-01 00:00:00'::timestamp without time zone))
Heap Blocks: exact=213
->  Bitmap Index Scan on idx_orders_status_member_id_ordered_at  (cost=0.00..255.42 rows=201 width=0) (actual time=0.970..0.972 rows=213 loops=1)
Index Cond: ((status = 'X'::bpchar) AND (ordered_at >= '2023-12-01 00:00:00'::timestamp without time zone))
Planning Time: 0.235 ms
Execution Time: 1.660 ms
(7 rows)
```

Heap Blocks 213개 탐색

## 정리
ordered_at의 인덱스를 추가하여 1471개의 heap blocks을 탐색하는 것에서 213개로 감소하였고, Heap I/O를 줄여 실행 시간을 단축하였다.

이번 테스트를 통해
- 조건에 맞는 데이터 수가 충분히 적어야 인덱스 추가 방식의 효율이 높아진다는 점
- 인덱스를 탐색하고 Bitmap을 생성하는 과정 자체도 상당한 비용이 될 수 있다는 점
을 확인했다.
