# orders 테이블 기존 인덱스에 컬럼 추가하여 성능 개선 1
실무에서는 인덱스를 새로 추가하거나 구성을 변경하기 쉽지 않다.
이때는 기존의 인덱스에 새로운 인덱스를 추가하는 것으로 개선할 수 있다.

## 필요한 쿼리
`SELECT * FROM orders WHERE status  = 'C' AND ordered_at >= '2023-01-01';`

## Step 1. 인덱스 없음
```-------------------------------------------------------------------------------------------------------------
Seq Scan on orders  (cost=0.00..4471.00 rows=24865 width=22) (actual time=0.021..10.335 rows=24978 loops=1)
Filter: ((ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone) AND (status = 'C'::bpchar))
Rows Removed by Filter: 175022
Planning Time: 0.083 ms
Execution Time: 11.117 ms
(5 rows)
```

## Step 2. [status + member_id]
이 경우는 이미 다른 status + member_id를 인덱스로 사용하는 쿼리가 있는 상황이다.
```-------------------------------------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on orders  (cost=1370.49..4345.19 rows=24865 width=22) (actual time=1.918..7.455 rows=24978 loops=1)
Recheck Cond: (status = 'C'::bpchar)
Filter: (ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone)
Rows Removed by Filter: 75022
Heap Blocks: exact=1471
->  Bitmap Index Scan on idx_orders_status_member_id  (cost=0.00..1364.27 rows=100247 width=0) (actual time=1.797..1.797 rows=100000 loops=1)
Index Cond: (status = 'C'::bpchar)
Planning Time: 0.061 ms
Execution Time: 7.952 ms
(9 rows)
```

## Step 3. [status + member_id + ordered_at]
기존의 [status + member_id] 인덱스를 그대로 사용하면서 ordered_at을 추가했다.
```-------------------------------------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on orders  (cost=2561.11..4405.08 rows=24865 width=22) (actual time=4.915..7.405 rows=24978 loops=1)
Recheck Cond: ((status = 'C'::bpchar) AND (ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone))
Heap Blocks: exact=1471
->  Bitmap Index Scan on idx_orders_status_member_id_ordered_at  (cost=0.00..2554.89 rows=24865 width=0) (actual time=4.710..4.711 rows=24978 loops=1)
Index Cond: ((status = 'C'::bpchar) AND (ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone))
Planning Time: 0.061 ms
Execution Time: 7.944 ms
(7 rows)
```

## Step 4. [status + ordered_at]
하지만 결국 [status + ordered_at]의 인덱스를 추가하는것이 최적이다.
```-----------------------------------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on orders  (cost=643.29..2487.26 rows=24865 width=22) (actual time=1.314..3.502 rows=24978 loops=1)
Recheck Cond: ((status = 'C'::bpchar) AND (ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone))
Heap Blocks: exact=1471
->  Bitmap Index Scan on idx_orders_status_ordered_at  (cost=0.00..637.07 rows=24865 width=0) (actual time=1.195..1.196 rows=24978 loops=1)
Index Cond: ((status = 'C'::bpchar) AND (ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone))
Planning Time: 0.066 ms
Execution Time: 4.015 ms
(7 rows)
```

## Step 5. [status + ordered_at] 커버드 인덱스 사용 유도
[status + ordered_at]을 그대로 사용하되, * 로 모든 컬럼을 가져오는 것이 아닌 인덱스의 컬럼만 가져오도록 쿼리를 변경한다.
### 쿼리
`SELECT status, ordered_at FROM orders WHERE status  = 'C' AND ordered_at >= '2023-01-01';`

```-----------------------------------------------------------------------------------------------------------------------------------------------------
Index Only Scan using idx_orders_status_ordered_at on orders  (cost=0.42..885.72 rows=24865 width=10) (actual time=0.027..1.882 rows=24978 loops=1)
Index Cond: ((status = 'C'::bpchar) AND (ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone))
Heap Fetches: 0
Planning Time: 0.072 ms
Execution Time: 2.451 ms
(5 rows)
```

인덱스에서만 데이터를 가져올 수 있으므로 Index Only Scan이 발생했다.
Heap Fetches: 0 -> Heap을 단 한번도 읽지 않음을 뜻한다.

## 정리
위 실행 계획들을 보면 Bitmap 이라는 단어가 반복해서 보인다.
Bitmap을 이해하기 전에 Block과 Record 관계에 대해서 먼저 이해가 필요하다.
Block이란 데이터베이스 I/O의 최소단위이다. (8Kb)
Block안에는 여러개의 Record가 포함될 수 있다. 그래서 단 한건의 레코드를 가져오기 위해서도 Block 단위로 I/O가 이루어지기 때문에 불필요한 데이터가 딸려올 수 있다.
(실행 계획에서 Recheck Cond가 있는 이유가 이 불필요한 데이터를 필터링하기 위함이다.)

Bitmap Scan의 목적은 조건에 맞는 Heap Block들을 먼저 수집한 뒤 Block들을 정렬된 순서로 접근하여 Random I/O를 줄이고, 보다 효율적인 디스크 접근을 수행하기 위함이다.

1. Bitmap Index Scan
   - 인덱스를 읽어 조건에 맞는 Row 위치를 찾는다.
   - 이를 기반으로 어떤 Block을 읽어야 하는지 Bitmap 형태로 생성한다.
2. Bitmap Heap Scan
   - 비트맵을 바탕으로 Block을 `순차적으로`읽는 과정이다.
   - 이후 실제 Row가 조건에 맞는지 재확인한다. (Bitmap 단계에서는 "이 Block 어딘가에 조건을 만족하는 Row가 있음" 정도만 알 수 있으므로, 실제 Block에서 다시 조건 검사를 수행한다.)

## 단계별 성능 비교

| 단계 | 인덱스 구성 | 인덱스 실제 읽은 rows | 비트맵 등록 rows | Heap I/O rows | 실행시간 |
|---|---|---|---------|---|---|
| Step 1 | 없음 (Seq Scan) | 200,000 | -       | 200,000 | ~20ms |
| Step 2 | status + member_id | 100,000 | 100,000 | 100,000 | 7.952ms |
| Step 3 | status + member_id + ordered_at | 100,000 | 24,978  | 24,978 | 7.944ms |
| Step 4 | status + ordered_at | 24,978 | 24,978  | 24,978 | 4.015ms |
| Step 5 | status + ordered_at (커버링) | 24,978 | 0       | 0 | 2.451ms |

## Step2와 Step3 재검토
`실무에서는 인덱스를 새로 추가하거나 구성을 변경하기 쉽지 않다.
이때는 기존의 인덱스에 새로운 인덱스를 추가하는 것으로 개선할 수 있다.`

Step2와 Step3에서의 튜닝이 위 상황에서의 최선이라고 생각했다.
하지만 쿼리 실행 시간이 비슷하여 성능 개선이 미미했다.
실행 계획을 보면 Bitmap Index Scan하는 과정에서 Step3의 시간은 4.710ms, Step2는 1.797ms이다.
[status + member_id + ordered_at]의 인덱스를 사용했지만 쿼리에서는 member_id에 대한 조건이 없어 ordered_at의 데이터를 효율적으로 사용하지 못한 것이다.
결국 index를 전체 스캔하는데, ordered_at이 조건에 맞는지 확인해야하므로 이 과정에서 더 시간이 들었던 것이다. 

포인트는 index를 스캔하는 시간을 줄이는 것이다.
현재 status = 'C'인 데이터가 10만개로 전체 데이터의 절반인데 시나리오 2번에서는 index 탐색 시간을 감소시키기 위해 조건에 맞는 데이터를 줄여 테스트 해보겠다. 