# work_mem과 Disk Spill

정렬(Sort), 해시 조인(Hash), 해시 집계(HashAggregate)는 중간 결과를 메모리에 올려두고 처리한다.
`work_mem`은 그 중간 결과에 허용되는 메모리 상한이다. 이 값을 넘으면 PostgreSQL은 실패하는 대신
**임시 파일을 디스크에 쓰고 계속 진행**한다. 이것이 disk spill이다.

여기서 두 가지를 관찰한다.

1. spill이 일어나면 실행 계획과 실행 시간이 어떻게 달라지는가
2. `work_mem`은 **쿼리당이 아니라 연산 노드당** 할당된다는 것 — 그래서 한 쿼리가 `work_mem`의 몇 배를 쓸 수 있는가

두 번째가 핵심이다. `work_mem = 64MB`로 설정했다고 해서 한 세션이 64MB만 쓰는 것이 아니다.

---

## 사전 준비

### 현재 설정 확인

```sql
SHOW work_mem;
SHOW hash_mem_multiplier;
SHOW max_parallel_workers_per_gather;
```

```
-- 결과 기록
```

이 실습 환경(`docker-compose-postgres.yml`)은 `work_mem = 64MB`로 시작한다. 기본값(4MB)보다 훨씬 크다.
`hash_mem_multiplier`는 **해시 계열 노드에만 곱해지는 배수**다. 이 값이 2.0이면 해시 노드는 `work_mem × 2`까지 쓴다.

`EXPLAIN`만으로는 spill을 볼 수 없다. 실제로 실행해야 하므로 반드시 `EXPLAIN (ANALYZE, BUFFERS)`를 쓴다.

```
\timing on
```

### 실험 조건 고정: 병렬 끄기

**모든 측정은 병렬을 끈 상태에서 한다.** 병렬을 켜는 것은 실험 3 Step 3 하나뿐이다.

```sql
SET max_parallel_workers_per_gather = 0;
```

`work_mem`을 낮추면 정렬·해시 비용 추정이 올라가고, 플래너는 그 비용을 나눠 갖기 위해 **병렬 계획을 고르기도 한다.**
그러면 `work_mem`만 바꿨는데 프로세스 수까지 같이 바뀌어, 시간 차이가 spill 때문인지 병렬 때문인지 구분할 수 없다.
실제로 병렬을 켠 채 실험 1·2를 돌리면 spill 쪽이 **더 빠르게** 나와 결론이 정반대로 뒤집힌다.

바꾸는 변수는 `work_mem` 하나여야 한다.

---

## 실험 1: 정렬에서 spill 관찰하기

60만 건 `order_item`을 인덱스 없는 컬럼으로 정렬시킨다.

### Step 1. work_mem을 줄여서 디스크로 밀어내기

```sql
SET work_mem = '64kB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_item ORDER BY unit_price;
```

```
-------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=116629.81..118129.81 rows=600000 width=22) (actual time=165.259..196.718 rows=600000 loops=1)
   Sort Key: unit_price
   Sort Method: external merge  Disk: 20024kB
   Buffers: shared hit=3822, temp read=9992 written=10694
   ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=22) (actual time=0.028..22.362 rows=600000 loops=1)
         Buffers: shared hit=3822
 Planning Time: 0.107 ms
 Execution Time: 212.689 ms
(8 rows)

Time: 213.236 ms
```

### Step 2. work_mem을 키워서 메모리 안에서 끝내기

```sql
SET work_mem = '256MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_item ORDER BY unit_price;
```

```
-------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=67405.81..68905.81 rows=600000 width=22) (actual time=90.353..165.205 rows=600000 loops=1)
   Sort Key: unit_price
   Sort Method: quicksort  Memory: 52702kB
   Buffers: shared hit=3822
   ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=22) (actual time=0.010..22.522 rows=600000 loops=1)
         Buffers: shared hit=3822
 Planning Time: 0.064 ms
 Execution Time: 179.838 ms
(8 rows)

Time: 180.299 ms
```

### Step 3. 경계 찾기

Step 2에서 나온 `Memory: NNNNkB` 값이 이 정렬에 필요한 메모리다. 그 근처로 `work_mem`을 조절하며 방법이 바뀌는 지점을 찾는다.

```sql
SET work_mem = '53MB';
EXPLAIN (ANALYZE) SELECT * FROM order_item ORDER BY unit_price;
```

```
-------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=67405.81..68905.81 rows=600000 width=22) (actual time=85.602..159.222 rows=600000 loops=1)
   Sort Key: unit_price
   Sort Method: quicksort  Memory: 46216kB
   ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=22) (actual time=0.008..22.184 rows=600000 loops=1)
 Planning Time: 0.087 ms
 Execution Time: 172.311 ms
(6 rows)

Time: 172.801 ms
```

| work_mem | Sort Method | 사용량 | 임시파일 I/O (read / written) | Execution Time |
|---|---|---|---|---|
| 64kB | **external merge** | Disk 20,024kB | 9,992 / 10,694 블록 ≈ 78 / 84MB | **212.7 ms** |
| 53MB | quicksort | Memory 46,216kB | — | 172.3 ms |
| 256MB | quicksort | Memory 52,702kB | — | 179.8 ms |

세 계획 모두 단일 프로세스 `Sort`다. 달라진 변수는 `work_mem` 하나뿐이므로 시간 차이를 그대로 읽을 수 있다.

**확인 포인트**

- `external merge`는 정렬 대상을 여러 조각으로 나눠 디스크에 쓴 뒤 병합한 것이다. `quicksort`는 전부 메모리에서 처리했다는 뜻이다.
- spill이 나도 쿼리는 실패하지 않는다. **조용히 느려질 뿐**이라 눈치채기 어렵다.
  여기서는 172~180ms → 212.7ms로 약 20% 느려졌다. 로그에 아무것도 남지 않는 20%다.
- `Buffers`의 `temp written=10,694`(≈84MB)가 `Disk: 20,024kB`(≈20MB)보다 **4배 이상** 크다.
  정렬 결과는 20MB인데 84MB를 쓴 것이다. `work_mem`이 극단적으로 작으면 만들어지는 조각(run)이 너무 많아
  한 번에 병합하지 못하고, 병합을 여러 패스로 나누며 같은 데이터를 반복해서 쓰고 읽기 때문으로 보인다.
  **실제 디스크 I/O는 `Disk:`에 찍힌 숫자보다 클 수 있다.**
- 53MB와 256MB의 `Memory` 값이 다른 것(46,216kB vs 52,702kB)도 눈여겨볼 만하다.
  정렬용 메모리는 한도까지 단계적으로 늘려가며 잡히므로, 한도가 낮으면 더 작은 단계에서 멈춘다.
  둘의 시간 차(172.3ms vs 179.8ms)는 오차 수준이다. **spill만 넘기면 그 위로 더 주는 것은 이득이 없다.**
  즉 목표는 "`work_mem`을 크게"가 아니라 "**spill 경계를 막 넘기는 지점**"이다.
- `LIMIT`을 붙이면 `top-N heapsort`로 바뀌어 spill이 사라지는지도 확인해보자.
  ```sql
  SET work_mem = '64kB';
  EXPLAIN (ANALYZE) SELECT * FROM order_item ORDER BY unit_price LIMIT 10;
  ```

---

## 실험 2: 해시 연산에서 spill 관찰하기

정렬만 spill 되는 것이 아니다. 해시 조인과 해시 집계도 마찬가지다.

### Step 1. Hash Join의 Batches

```sql
SET work_mem = '64kB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_item oi JOIN orders o ON o.order_id = oi.order_id;
```

```
-----------------------------------------------------------------------------------------------------------------------------
 Hash Join  (cost=7143.00..26744.03 rows=594757 width=44) (actual time=38.860..239.173 rows=600000 loops=1)
   Hash Cond: (oi.order_id = o.order_id)
   Buffers: shared hit=5293, temp read=4495 written=4495
   ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=22) (actual time=0.009..22.918 rows=600000 loops=1)
         Buffers: shared hit=3822
   ->  Hash  (cost=3471.00..3471.00 rows=200000 width=22) (actual time=38.016..38.016 rows=200000 loops=1)
         Buckets: 2048  Batches: 128  Memory Usage: 110kB
         Buffers: shared hit=1471, temp written=1106
         ->  Seq Scan on orders o  (cost=0.00..3471.00 rows=200000 width=22) (actual time=0.002..10.965 rows=200000 loops=1)
               Buffers: shared hit=1471
 Planning:
   Buffers: shared hit=9
 Planning Time: 0.473 ms
 Execution Time: 253.643 ms
(14 rows)
```

```sql
SET work_mem = '64MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_item oi JOIN orders o ON o.order_id = oi.order_id;
```

```
----------------------------------------------------------------------------------------------------------------------------
 Hash Join  (cost=5971.00..17368.03 rows=594757 width=44) (actual time=28.893..193.959 rows=600000 loops=1)
   Hash Cond: (oi.order_id = o.order_id)
   Buffers: shared hit=5293
   ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=22) (actual time=0.006..25.163 rows=600000 loops=1)
         Buffers: shared hit=3822
   ->  Hash  (cost=3471.00..3471.00 rows=200000 width=22) (actual time=28.625..28.626 rows=200000 loops=1)
         Buckets: 262144  Batches: 1  Memory Usage: 13767kB
         Buffers: shared hit=1471
         ->  Seq Scan on orders o  (cost=0.00..3471.00 rows=200000 width=22) (actual time=0.010..8.217 rows=200000 loops=1)
               Buffers: shared hit=1471
 Planning:
   Buffers: shared hit=9
 Planning Time: 0.248 ms
 Execution Time: 208.792 ms
(14 rows)

Time: 209.456 ms
```

**확인 포인트**: `Batches: 1`은 해시 테이블 전체가 메모리에 들어갔다는 뜻이다.
`Batches: 8`이면 조인 대상을 8조각으로 나눠 디스크를 오가며 처리한 것이다. 여기서는 `Disk:` 문구가 없으므로 **Batches 숫자가 spill의 신호**다.

### Step 2. HashAggregate의 Disk Usage

```sql
SET work_mem = '64kB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, SUM(qty * unit_price) FROM order_item GROUP BY order_id;
```

```
-------------------------------------------------------------------------------------------------------------------------------
 GroupAggregate  (cost=108425.81..116443.44 rows=201763 width=12) (actual time=141.755..225.712 rows=200000 loops=1)
   Group Key: order_id
   Buffers: shared hit=3822, temp read=6471 written=7056
   ->  Sort  (cost=108425.81..109925.81 rows=600000 width=10) (actual time=141.716..174.726 rows=600000 loops=1)
         Sort Key: order_id
         Sort Method: external merge  Disk: 12984kB
         Buffers: shared hit=3822, temp read=6471 written=7056
         ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=10) (actual time=4.244..32.589 rows=600000 loops=1)
               Buffers: shared hit=3822
 Planning Time: 0.126 ms
 JIT:
   Functions: 7
   Options: Inlining false, Optimization false, Expressions true, Deforming true
   Timing: Generation 0.723 ms, Inlining 0.000 ms, Optimization 0.368 ms, Emission 3.876 ms, Total 4.967 ms
 Execution Time: 232.712 ms
(15 rows)

Time: 233.444 ms
```

```sql
SET work_mem = '64MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, SUM(qty * unit_price) FROM order_item GROUP BY order_id;
```

```
-------------------------------------------------------------------------------------------------------------------------
 HashAggregate  (cost=14322.00..16339.63 rows=201763 width=12) (actual time=126.889..155.943 rows=200000 loops=1)
   Group Key: order_id
   Batches: 1  Memory Usage: 28689kB
   Buffers: shared hit=3822
   ->  Seq Scan on order_item  (cost=0.00..9822.00 rows=600000 width=10) (actual time=0.020..21.970 rows=600000 loops=1)
         Buffers: shared hit=3822
 Planning Time: 0.075 ms
 Execution Time: 161.613 ms
(8 rows)

Time: 162.148 ms
```

### Step 3. 두 연산 비교

| 연산 | work_mem | 선택된 계획 | spill 신호 | 메모리 / 디스크 | Execution Time |
|---|---|---|---|---|---|
| Hash Join | 64kB | Hash Join | **Batches: 128** (Buckets 2,048) | Memory 110kB + temp 4,495블록 ≈ 35MB | **253.6 ms** |
| Hash Join | 64MB | Hash Join *(동일)* | Batches: 1 (Buckets 262,144) | Memory 13,767kB | 208.8 ms |
| 그룹 집계 | 64kB | **Sort + GroupAggregate** | external merge | Disk 12,984kB, temp written 7,056블록 ≈ 55MB | **232.7 ms** |
| 그룹 집계 | 64MB | **HashAggregate** | Batches: 1 | Memory 28,689kB | 161.6 ms |

**확인 포인트**

- Hash Join은 **계획이 그대로인 채** `Batches`만 1 → 128로 바뀌었다. 해시 테이블이 `work_mem`에 안 들어가자
  조인 대상을 128조각으로 쪼개 디스크를 오간 것이고, 시간도 208.8ms → 253.6ms로 정직하게 느려졌다.
  **`Disk:` 문구가 없으므로 `Batches` 숫자가 유일한 신호다.**
- `Buckets`도 262,144 → 2,048으로 줄었다. 메모리가 없으니 버킷을 성기게 잡은 것이고, 그만큼 해시 충돌도 늘어난다.
- 반면 그룹 집계는 **계획 자체가 바뀌었다.** `HashAggregate`가 들어갈 메모리가 없다고 판단되면
  플래너는 `Sort + GroupAggregate`로 갈아탄다(161.6ms → 232.7ms, 44% 느려짐).
  즉 `work_mem`은 실행 속도뿐 아니라 **어떤 실행 계획이 선택되는지**까지 바꾼다.
- 64kB 쪽 그룹 집계 계획에는 `JIT` 블록이 붙었다. 비용 추정이 108,425로 뛰면서 JIT 임계값을 넘겼기 때문이다.
  `work_mem` 하나가 **계획 선택 → 비용 추정 → JIT 발동**까지 연쇄로 건드린다.
- Hash Join의 `Memory Usage: 13,767kB`는 `work_mem`(64MB)에 한참 못 미친다.
  해시 테이블이 `work_mem`을 넘길 때 비로소 `Batches`가 늘어나므로, 이 값이 `work_mem`에 가까워지고 있는지가 위험 신호다.

---

## 실험 3: work_mem은 곱해진다

여기가 이 문서의 핵심이다. `work_mem`은 세션당도, 쿼리당도 아닌 **연산 노드당** 한도다.

### Step 1. 메모리를 쓰는 노드가 여러 개인 쿼리

조인 3개 + 그룹핑 + 정렬이 한 쿼리에 들어있다.

```sql
SET work_mem = '64MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT m.region,
       p.category_id,
       SUM(oi.qty * oi.unit_price) AS amount
FROM order_item oi
         JOIN orders  o ON o.order_id   = oi.order_id
         JOIN member  m ON m.member_id  = o.member_id
         JOIN product p ON p.product_id = oi.product_id
GROUP BY 1, 2
ORDER BY amount DESC;
```

```
----------------------------------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=28334.89..28335.27 rows=150 width=17) (actual time=394.957..394.966 rows=150 loops=1)
   Sort Key: (sum((oi.qty * oi.unit_price))) DESC
   Sort Method: quicksort  Memory: 32kB
   Buffers: shared hit=5893
   ->  HashAggregate  (cost=28327.97..28329.47 rows=150 width=17) (actual time=394.924..394.937 rows=150 loops=1)
         Group Key: m.region, p.category_id
         Batches: 1  Memory Usage: 48kB
         Buffers: shared hit=5893
         ->  Hash Join  (cost=7921.00..22430.23 rows=589774 width=15) (actual time=43.273..324.175 rows=600000 loops=1)
               Hash Cond: (oi.product_id = p.product_id)
               Buffers: shared hit=5893
               ->  Hash Join  (cost=7612.00..20570.40 rows=590541 width=17) (actual time=40.651..263.650 rows=600000 loops=1)
                     Hash Cond: (o.member_id = m.member_id)
                     Buffers: shared hit=5809
                     ->  Hash Join  (cost=5971.00..17368.03 rows=594757 width=14) (actual time=32.918..177.068 rows=600000 loops=1)
                           Hash Cond: (oi.order_id = o.order_id)
                           Buffers: shared hit=5293
                           ->  Seq Scan on order_item oi  (cost=0.00..9822.00 rows=600000 width=14) (actual time=0.008..23.020 rows=600000 loops=1)
                                 Buffers: shared hit=3822
                           ->  Hash  (cost=3471.00..3471.00 rows=200000 width=8) (actual time=32.788..32.789 rows=200000 loops=1)
                                 Buckets: 262144  Batches: 1  Memory Usage: 9861kB
                                 Buffers: shared hit=1471
                                 ->  Seq Scan on orders o  (cost=0.00..3471.00 rows=200000 width=8) (actual time=0.004..10.427 rows=200000 loops=1)
                                       Buffers: shared hit=1471
                     ->  Hash  (cost=1016.00..1016.00 rows=50000 width=11) (actual time=7.677..7.678 rows=50000 loops=1)
                           Buckets: 65536  Batches: 1  Memory Usage: 2661kB
                           Buffers: shared hit=516
                           ->  Seq Scan on member m  (cost=0.00..1016.00 rows=50000 width=11) (actual time=0.040..4.202 rows=50000 loops=1)
                                 Buffers: shared hit=516
               ->  Hash  (cost=184.00..184.00 rows=10000 width=6) (actual time=2.607..2.607 rows=10000 loops=1)
                     Buckets: 16384  Batches: 1  Memory Usage: 519kB
                     Buffers: shared hit=84
                     ->  Seq Scan on product p  (cost=0.00..184.00 rows=10000 width=6) (actual time=0.007..1.155 rows=10000 loops=1)
                           Buffers: shared hit=84
 Planning:
   Buffers: shared hit=21
 Planning Time: 0.312 ms
 Execution Time: 395.048 ms
(38 rows)
```

### Step 2. 노드별 메모리 사용량을 모아 보기

계획에서 `Memory Usage:` 와 `Disk:` 가 찍힌 줄만 모아 표를 채운다.

| 노드 | Memory Usage | Batches / Disk | 이 노드에 허용된 한도 |
|---|---|---|---|
| Hash (orders) | 9,861kB | Batches: 1 | work_mem × hash_mem_multiplier = 128MB |
| Hash (member) | 2,661kB | Batches: 1 | 128MB |
| Hash (product) | 519kB | Batches: 1 | 128MB |
| HashAggregate | 48kB | Batches: 1 | 128MB |
| Sort | 32kB | quicksort | work_mem = 64MB |
| **합계** | **13,121kB ≈ 12.8MB** | spill 없음 | **576MB** |

**확인 포인트**

- 실제로 쓴 양은 12.8MB지만, **한도는 576MB**다. 노드 5개가 각자 독립적으로 자기 몫을 잡을 수 있기 때문이다.
  `work_mem = 64MB`라는 설정값 하나만 보고 "세션당 64MB"로 계산하면 **9배**를 놓친다.
- 이번 쿼리는 조인 대상(`orders` 20만, `member` 5만, `product` 1만)이 작아서 한도 근처에도 못 갔다.
  데이터가 10배 커지면 합계는 커지지만 **한도 576MB는 그대로**다. 즉 한도는 데이터가 아니라 **계획의 모양**이 정한다.
- 합계보다 중요한 것은 **노드 개수**다. 조인을 하나 더 붙이면 한도가 128MB 늘어난다.

### Step 3. 병렬 실행이 또 한 번 곱한다

병렬 워커는 각자 자기 몫의 `work_mem`을 쓴다.

```sql
SET max_parallel_workers_per_gather = 4;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;

EXPLAIN (ANALYZE, BUFFERS)
SELECT m.region,
       p.category_id,
       SUM(oi.qty * oi.unit_price) AS amount
FROM order_item oi
         JOIN orders  o ON o.order_id   = oi.order_id
         JOIN member  m ON m.member_id  = o.member_id
         JOIN product p ON p.product_id = oi.product_id
GROUP BY 1, 2
ORDER BY amount DESC;
```

```
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Sort  (cost=11528.99..11529.37 rows=150 width=17) (actual time=124.162..127.429 rows=150 loops=1)
   Sort Key: (sum((oi.qty * oi.unit_price))) DESC
   Sort Method: quicksort  Memory: 32kB
   Buffers: shared hit=6009
   ->  Finalize GroupAggregate  (cost=11508.73..11523.57 rows=150 width=17) (actual time=123.843..127.388 rows=150 loops=1)
         Group Key: m.region, p.category_id
         Buffers: shared hit=6009
         ->  Gather Merge  (cost=11508.73..11517.57 rows=600 width=17) (actual time=123.831..127.282 rows=750 loops=1)
               Workers Planned: 4
               Workers Launched: 4
               Buffers: shared hit=6009
               ->  Sort  (cost=11508.67..11509.05 rows=150 width=17) (actual time=104.321..104.335 rows=150 loops=5)
                     Sort Key: m.region, p.category_id
                     Sort Method: quicksort  Memory: 32kB
                     Buffers: shared hit=6009
                     Worker 0:  Sort Method: quicksort  Memory: 32kB
                     Worker 1:  Sort Method: quicksort  Memory: 32kB
                     Worker 2:  Sort Method: quicksort  Memory: 32kB
                     Worker 3:  Sort Method: quicksort  Memory: 32kB
                     ->  Partial HashAggregate  (cost=11501.75..11503.25 rows=150 width=17) (actual time=103.519..103.539 rows=150 loops=5)
                           Group Key: m.region, p.category_id
                           Batches: 1  Memory Usage: 48kB
                           Buffers: shared hit=5949
                           Worker 0:  Batches: 1  Memory Usage: 48kB
                           Worker 1:  Batches: 1  Memory Usage: 48kB
                           Worker 2:  Batches: 1  Memory Usage: 48kB
                           Worker 3:  Batches: 1  Memory Usage: 48kB
                           ->  Parallel Hash Join  (cost=3533.50..10027.31 rows=147444 width=15) (actual time=20.299..85.712 rows=120000 loops=5)
                                 Hash Cond: (oi.product_id = p.product_id)
                                 Buffers: shared hit=5949
                                 ->  Parallel Hash Join  (cost=3393.25..9499.35 rows=147635 width=17) (actual time=19.429..69.498 rows=120000 loops=5)
                                       Hash Cond: (o.member_id = m.member_id)
                                       Buffers: shared hit=5809
                                       ->  Parallel Hash Join  (cost=2596.00..8311.76 rows=148689 width=14) (actual time=17.056..49.594 rows=120000 loops=5)
                                             Hash Cond: (oi.order_id = o.order_id)
                                             Buffers: shared hit=5293
                                             ->  Parallel Seq Scan on order_item oi  (cost=0.00..5322.00 rows=150000 width=14) (actual time=0.008..6.776 rows=120000 loops=5)
                                                   Buffers: shared hit=3822
                                             ->  Parallel Hash  (cost=1971.00..1971.00 rows=50000 width=8) (actual time=15.935..15.937 rows=40000 loops=5)
                                                   Buckets: 262144  Batches: 1  Memory Usage: 9984kB
                                                   Buffers: shared hit=1471
                                                   ->  Parallel Seq Scan on orders o  (cost=0.00..1971.00 rows=50000 width=8) (actual time=0.017..2.569 rows=40000 loops=5)
                                                         Buffers: shared hit=1471
                                       ->  Parallel Hash  (cost=641.00..641.00 rows=12500 width=11) (actual time=2.117..2.118 rows=10000 loops=5)
                                             Buckets: 65536  Batches: 1  Memory Usage: 2880kB
                                             Buffers: shared hit=516
                                             ->  Parallel Seq Scan on member m  (cost=0.00..641.00 rows=12500 width=11) (actual time=0.009..3.390 rows=50000 loops=1)
                                                   Buffers: shared hit=516
                                 ->  Parallel Hash  (cost=109.00..109.00 rows=2500 width=6) (actual time=0.709..0.709 rows=2000 loops=5)
                                       Buckets: 16384  Batches: 1  Memory Usage: 544kB
                                       Buffers: shared hit=84
                                       ->  Parallel Seq Scan on product p  (cost=0.00..109.00 rows=2500 width=6) (actual time=0.013..1.328 rows=10000 loops=1)
                                             Buffers: shared hit=84
 Planning:
   Buffers: shared hit=21
 Planning Time: 0.366 ms
 Execution Time: 127.497 ms
(57 rows)                                             
```

`Workers Launched: 4` → 메모리를 쓰는 프로세스는 **워커 4개 + 리더 1개 = 5개**다.

| 노드 | 표시된 Memory Usage | 프로세스별로 곱해지는가 | 실제 총량 |
|---|---|---|---|
| Parallel Hash (orders) | 9,984kB | ✗ (공유 해시 테이블) | 9,984kB |
| Parallel Hash (member) | 2,880kB | ✗ | 2,880kB |
| Parallel Hash (product) | 544kB | ✗ | 544kB |
| Partial HashAggregate | 48kB (프로세스마다) | ○ | 48 × 5 = 240kB |
| Sort (Gather Merge 입력) | 32kB (프로세스마다) | ○ | 32 × 5 = 160kB |
| Sort (최종, 리더만) | 32kB | — | 32kB |
| **합계** | | | **13,840kB ≈ 13.5MB** |

| 구분 | 메모리를 쓰는 노드 | 프로세스 | 실제 합계 | Execution Time |
|---|---|---|---|---|
| Step 1 (비병렬) | 5 | 1 | 12.8MB | 395.0 ms |
| Step 3 (병렬, 워커 4) | 6 | 5 | 13.5MB | **127.5 ms** |

**확인 포인트**

- 3.1배 빨라졌는데 메모리는 12.8MB → 13.5MB로 거의 그대로다. **`Parallel Hash` 덕분**이다.
  워커들이 해시 테이블을 각자 만들지 않고 **하나를 공유**하기 때문에 프로세스 수만큼 복제되지 않는다.
  실제로 `orders` 해시가 비병렬 9,861kB → 병렬 9,984kB로 거의 같다.
- 반대로 `Partial HashAggregate`와 `Sort`처럼 **프로세스마다 따로 만드는 노드는 그대로 곱해진다.**
  계획에 `Worker 0/1/2/3:` 줄이 따로 찍히는 노드가 그것이다.
- 계획에 `Parallel Hash`가 아니라 그냥 `Hash`가 `Gather` 아래에 있으면, 워커마다 해시 테이블을 **각자 복제**한다.
  이 경우 곱셈이 그대로 적용되므로 계획에서 두 이름을 구별해서 봐야 한다.

### Step 4. 곱셈 정리

한 서버가 최악의 경우 쓰는 메모리는 대략 이렇게 계산된다.

```
work_mem
  × 메모리를 쓰는 노드 수          (실험 3 Step 2)
  × (병렬 워커 수 + 1)             (실험 3 Step 3)
  × 동시에 그 쿼리를 실행하는 세션 수
  ( × hash_mem_multiplier, 해시 계열 노드에 한해 )
```

이 실습 환경의 값으로 직접 계산해본다. (Step 1의 비병렬 계획 기준)

```
해시 노드 4개 × (work_mem 64MB × hash_mem_multiplier 2.0) = 512MB
정렬 노드 1개 ×  work_mem 64MB                            =  64MB
                                                    1세션 = 576MB
```

| 동시 세션 | 최악의 경우 메모리 |
|---|---|
| 1 | 576MB |
| 5 | 2.8GB |
| 10 | **5.6GB** |

| 비교 대상 | 크기 | 성격 |
|---|---|---|
| `shared_buffers` | 256MB | 기동 시 **한 번** 잡고 끝 |
| `work_mem` 기반 최악치 (10세션) | 5.6GB | 쿼리가 들어올 때마다 **새로** 할당 |

**확인 포인트**

- 설정 파일에 적힌 숫자는 `work_mem = 64MB` 하나지만, 실제 상한은 그 **9배 × 세션 수**다.
- `shared_buffers`는 기동 시 한 번 잡아두는 고정 영역이라 예측이 쉽지만, `work_mem`은 필요할 때마다 새로 할당된다.
  그래서 **평소에는 멀쩡하다가 동시 실행이 몰리는 순간 OOM**으로 이어진다.
- 실제 측정값(12.8MB)과 한도(576MB)의 간극이 이 문제의 본질이다.
  평소 관측으로는 안전해 보이지만, 데이터가 커져 각 노드가 한도까지 차오르면 그때 한 번에 터진다.

---

## 전체 정리

| 관찰 대상 | 계획에 찍히는 신호 |
|---|---|
| Sort spill | `Sort Method: external merge  Disk: NNNNkB` |
| Sort 정상 | `Sort Method: quicksort  Memory: NNNNkB` |
| Hash Join spill | `Batches: 2` 이상 |
| HashAggregate spill | `Batches: 2` 이상 + `Disk Usage: NNNNkB` |
| 서버 전체 누적 | `pg_stat_database.temp_files / temp_bytes` |

핵심 세 가지:

1. **spill은 실패하지 않는다. 조용히 20~44% 느려진다.** 그래서 `EXPLAIN ANALYZE`로 직접 보지 않으면 모른 채 지나간다.
   게다가 `work_mem`은 계획 선택(실험 2)과 병렬 여부까지 바꾸므로, **병렬을 끄고 변수를 하나로 고정해야** 원인을 바로 읽을 수 있다.
2. **`work_mem`은 쿼리당이 아니라 노드당이다.** 설정값은 64MB지만 이 쿼리 하나의 한도는 576MB, 9배였다.
   해시 계열 노드는 여기에 `hash_mem_multiplier`가 한 번 더 곱해진다.
3. **프로세스마다 따로 만드는 노드는 병렬도에 다시 곱해진다.** 다만 `Parallel Hash`처럼 공유되는 노드는 곱해지지 않으므로,
   계획에서 `Worker N:` 줄이 따로 찍히는 노드가 무엇인지 보고 판단해야 한다.
4. **그 위에 동시 세션 수가 곱해진다.** `work_mem`을 전역으로 올리는 것이 위험한 이유다.

그래서 실무의 선택은 보통 이렇다.

- 전역 `work_mem`은 보수적으로 두고, 무거운 배치 쿼리에서만 세션 단위로 `SET work_mem`
- 애초에 정렬이 필요 없도록 인덱스를 만들어 `Sort` 노드 자체를 없애기
- spill이 나는 쿼리를 먼저 찾기 → `log_temp_files = 0` 설정 후 로그 확인 (`docker logs sql-tuning-postgres`)

---

## 실습 정리

세션 파라미터는 접속을 끊으면 사라지지만, 이어서 다른 실습을 한다면 되돌려 둔다.

```sql
RESET work_mem;
RESET max_parallel_workers_per_gather;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;

SHOW work_mem;
```
