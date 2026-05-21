# NL 조인 튜닝

PostgreSQL에서 옵티마이저 hint를 사용하기 위해 extension을 설치하고 적용하였다.<br>
`/*+ NestLoop(a b) */`와 같이 힌트를 주어 NL 조인을 유도할 수 있다.

사용 쿼리<br>
```sql
SELECT m.member_id, m.name, m.grade, o.order_id, o.ordered_at, o.total_amount
FROM member m
JOIN orders o ON o.member_id = m.member_id
WHERE m.grade = 'A';
```

grade가 A인 member는 1500건, orders는 총 20만건이다.

## Step 1. orders 테이블 member_id 컬럼에 인덱스가 없는 경우

```
---------------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.30..24402.88 rows=6000 width=35) (actual time=0.073..69.670 rows=6000 loops=1)
   Buffers: shared hit=151471
   ->  Seq Scan on orders o  (cost=0.00..3471.00 rows=200000 width=20) (actual time=0.009..6.755 rows=200000 loops=1)
         Buffers: shared hit=1471
   ->  Memoize  (cost=0.30..0.33 rows=1 width=19) (actual time=0.000..0.000 rows=0 loops=200000)
         Cache Key: o.member_id
         Cache Mode: logical
         Hits: 150000  Misses: 50000  Evictions: 0  Overflows: 0  Memory Usage: 3396kB
         Buffers: shared hit=150000
         ->  Index Scan using member_pkey on member m  (cost=0.29..0.32 rows=1 width=19) (actual time=0.001..0.001 rows=0 loops=50000)
               Index Cond: (member_id = o.member_id)
               Filter: (grade = 'A'::bpchar)
               Rows Removed by Filter: 1
               Buffers: shared hit=150000
 Planning Time: 0.117 ms
 Execution Time: 69.905 ms
(16 rows)
```

1. order에서 Seq Scan으로 row하나 꺼냄
2. 그 row의 member_id로 Memoize 캐시 확인
3.  
   - 3-A. 캐시에 없으면 (Miss) Index Scan으로 member PK 탐색 -> grade = 'A' 필터 적용 -> 결과 캐시 저장 
     - 하지만 grade != 'A' 결과도 빈 행으로 캐싱된다. 다음에 똑같은 member_id를 만났을 때 재탐색하지 않기 위함 (이를 Negative Caching 이라고 한다.)
   - 3-B. 캐시에 있으면 (Hit) 캐시에서 바로 꺼냄 (I/O 없음)
4. 조인 결과 조합
5. orders 다음 row 꺼내서 1번부터 반복 (200000번)

memoization의 hits 150000, miss 50000건으로 보아 cache 히트율이 75%인 것을 알 수 있다.

## Step 2. Memoize 없이 실행
`set enable_memoize = off;`

```
----------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.29..68090.87 rows=6000 width=35) (actual time=0.084..121.548 rows=6000 loops=1)
   Buffers: shared hit=601471
   ->  Seq Scan on orders o  (cost=0.00..3471.00 rows=200000 width=20) (actual time=0.009..6.923 rows=200000 loops=1)
         Buffers: shared hit=1471
   ->  Index Scan using member_pkey on member m  (cost=0.29..0.32 rows=1 width=19) (actual time=0.000..0.000 rows=0 loops=200000)
         Index Cond: (member_id = o.member_id)
         Filter: (grade = 'A'::bpchar)
         Rows Removed by Filter: 1
         Buffers: shared hit=600000
 Planning Time: 0.129 ms
 Execution Time: 121.738 ms
(11 rows)
```

이게 Memoize가 없는 정석적인 NL 조인이다. <br>
그럼 왜 옵티마이저는 orders를 자꾸 outer로 선택하는 걸까? (심지어 Leading 힌트를 주어 member 테이블을 outer로 지정해도 무시된다.)
1. orders가 outer인 경우
   1. outer인 20만건의 orders를 단 1번만 처음부터 읽는다. (Seq Scan)
   2. inner를 찾을때는 member_pkey 인덱스가 있다 (primary key 인덱스)
   3. 따라서 20만번 루프를 돌지만, 매번 인덱스를 타고 빠르게 회원을 찾는다.
   - 총 연산량: 20만건 읽기 + 20만 번의 인덱스 탐색
2. member가 outer인 경우
   1. outer인 1500건의 member를 Seq Scan한다.
   2. inner를 찾을 때 인덱스가 없다.
   3. member에서 행 1개를 꺼낼때마다 테이블 20만건 전체를 맨 처음부터 끝까지 다 뒤져야한다.
   - 총 연산량: 1500 x 20만건 풀 스캔 = 3억 번의 디스크 탐색

## Step 3. 인덱스가 있는 경우 

`create index idx_orders_member_id on orders (member_id);`

```
-----------------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.42..9022.16 rows=6000 width=35) (actual time=0.024..6.378 rows=6000 loops=1)
   Buffers: shared hit=11016
   ->  Seq Scan on member m  (cost=0.00..1141.00 rows=1500 width=19) (actual time=0.010..2.439 rows=1500 loops=1)
         Filter: (grade = 'A'::bpchar)
         Rows Removed by Filter: 48500
         Buffers: shared hit=516
   ->  Index Scan using idx_orders_member_id on orders o  (cost=0.42..5.21 rows=4 width=20) (actual time=0.001..0.002 rows=4 loops=1500)
         Index Cond: (member_id = m.member_id)
         Buffers: shared hit=10500
 Planning Time: 0.133 ms
 Execution Time: 6.544 ms
(11 rows)
```

orders의 member_id에 인덱스를 생성해주었더니, 옵티마이저는 별다른 Leading 힌트 없이도 member 테이블을 outer로 사용하도록 설정하였다.
1. member에서 Seq Scan으로 전체를 다 읽으면서, grade = 'A' 조건에 맞는 행 필터링하여 조회
2. 그 행의 member_id를 바탕으로 orders의 member_id 인덱스를 사용하여 orders 데이터 Random I/O로 가져옴
3. 결과 조합
4. member 다음 row 꺼내서 1번부터 반복 (1500번)

## Step 4. member 테이블의 grade를 인덱스로 추가

`create index idx_member_grade on member (grade);`<br>
outer 테이블의 Seq Scan을 없애기 위해 grade로 인덱스를 생성하였다.

```
-----------------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=20.34..8435.83 rows=6000 width=35) (actual time=0.094..4.799 rows=6000 loops=1)
   Buffers: shared hit=11013
   ->  Bitmap Heap Scan on member m  (cost=19.91..554.66 rows=1500 width=19) (actual time=0.084..0.529 rows=1500 loops=1)
         Recheck Cond: (grade = 'A'::bpchar)
         Heap Blocks: exact=510
         Buffers: shared hit=513
         ->  Bitmap Index Scan on idx_member_grade  (cost=0.00..19.54 rows=1500 width=0) (actual time=0.052..0.052 rows=1500 loops=1)
               Index Cond: (grade = 'A'::bpchar)
               Buffers: shared hit=3
   ->  Index Scan using idx_orders_member_id on orders o  (cost=0.42..5.21 rows=4 width=20) (actual time=0.001..0.002 rows=4 loops=1500)
         Index Cond: (member_id = m.member_id)
         Buffers: shared hit=10500
 Planning Time: 0.136 ms
 Execution Time: 4.987 ms
(14 rows)
```

## Step 5. 커버링 인덱스
`create index idx_orders_member_id on orders (member_id);`<br>
`create index idx_member_grade on member (grade) include (member_id, name);`<br>
outer 테이블의 I/O를 없애기 위해 select 절에 사용되는 name과 member_id도 include 인덱스에 추가하였다.

```
----------------------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.83..7939.83 rows=6000 width=35) (actual time=0.036..4.131 rows=6000 loops=1)
   Buffers: shared hit=10511
   ->  Index Only Scan using idx_member_grade on member m  (cost=0.41..58.66 rows=1500 width=19) (actual time=0.023..0.127 rows=1500 loops=1)
         Index Cond: (grade = 'A'::bpchar)
         Heap Fetches: 0
         Buffers: shared hit=11
   ->  Index Scan using idx_orders_member_id on orders o  (cost=0.42..5.21 rows=4 width=20) (actual time=0.001..0.002 rows=4 loops=1500)
         Index Cond: (member_id = m.member_id)
         Buffers: shared hit=10500
 Planning Time: 0.112 ms
 Execution Time: 4.289 ms
(11 rows)
```

## 정리
NL 조인 튜닝 조건
1. inner에는 index가 있어야 한다는 점
2. outer 데이터가 적어야 성능 향상

**inner에 index가 없었던 Step 1에서 옵티마이저는 member를 outer로 고를 수가 없었다.**<br>
튜닝 조건 1과 2를 모두 만족하는 Step 2에서 최고의 성능을 낼 수 있었다.

1. 인덱스 없고, Memoize가 있을 때 - 69.905 ms
2. 인덱스 없고, Memoize도 없을 때 - 121.738 ms
3. 인덱스가 있을 때 - 6.544 ms