# 클러스터링 팩터 차이에 따른 인덱스 효율 확인

클러스터링 팩터란?
- 인덱스 키 순서와 테이블의 실제 물리적 순서가 얼마나 일치하는지 나타내는 지표
- 인덱스를 순서대로 읽을 때 테이블 블록을 몇 번 이동하는지 카운트한 값
- 즉, 값이 낮아야 데이터가 잘 정렬되어 있음을 뜻함

클러스터링 팩터 테스트를 위해 테이블을 2가지 생성하고 인덱스를 구성하였다.<br>
`CREATE TABLE orders_clustered AS SELECT * FROM orders ORDER BY ordered_at;`<br>
`CREATE TABLE orders_unclustered AS SELECT * FROM orders ORDER BY RANDOM();`

`CREATE INDEX idx_clustered_ordered_at ON orders_clustered(ordered_at);`<br>
`CREATE INDEX idx_unclustered_ordered_at ON orders_unclustered(ordered_at);`

또한 Seq Scan과 Bitmap Scan이 사용되지 않도록 두가지 옵션을 꺼놨다.<br>
`SET enable_bitmapscan = OFF;`<br>
`SET enable_seqscan = OFF;`

## Step 1. 정렬하여 만든 테이블 조회
```
-----------------------------------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_clustered_ordered_at on orders_clustered  (cost=0.42..462.52 rows=11955 width=22) (actual time=0.020..1.962 rows=12183 loops=1)
   Index Cond: ((ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone) AND (ordered_at <= '2023-03-31 00:00:00'::timestamp without time zone))
   Buffers: shared hit=127
 Planning Time: 0.102 ms
 Execution Time: 2.614 ms
(5 rows)
```

## Step 2. RANDOM으로 만든 테이블 조회
```
-----------------------------------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_unclustered_ordered_at on orders_unclustered  (cost=0.42..6257.20 rows=11848 width=22) (actual time=0.056..5.248 rows=12183 loops=1)
   Index Cond: ((ordered_at >= '2023-01-01 00:00:00'::timestamp without time zone) AND (ordered_at <= '2023-03-31 00:00:00'::timestamp without time zone))
   Buffers: shared hit=12210
 Planning Time: 0.115 ms
 Execution Time: 5.677 ms
(5 rows)
```

## 정리
Buffers의 shared hit 숫자를 보면 명확한 차이가 보인다.<br>
결과는 12183 행으로 똑같이 나왔지만, Step 1에서는 shared hit = 127, Step 2에서는 shared hit = 12,210개가 나와 Step 2가 약 96배 더 많은 버퍼에 접근했다.<br>
이는 실행시간에도 영향을 주어 Step 2는 Step 1에 비해 약 2배 이상의 시간이 들었다.

예시 그림
```
orders_clustered (ordered_at 순서로 저장)

블록1: [2023-01-01 row] [2023-01-01 row] [2023-01-01 row] [2023-01-02 row] ...
블록2: [2023-01-15 row] [2023-01-15 row] [2023-01-16 row] [2023-01-17 row] ...
블록3: [2023-02-01 row] [2023-02-01 row] [2023-02-02 row] [2023-02-03 row] ...
...
블록127: [2023-03-30 row] [2023-03-31 row] ...

→ 블록 127개만 순서대로 읽으면 12,183건 전부 나옴
```

```
orders_unclustered (랜덤 순서로 저장)

블록1:    [2022-05-10 row] [2023-02-14 row] [2020-11-03 row] [2023-01-07 row] ...
블록2:    [2021-08-22 row] [2023-03-15 row] [2022-01-01 row] [2020-07-19 row] ...
블록3:    [2023-01-22 row] [2021-04-30 row] [2023-02-08 row] [2020-12-25 row] ...
...
블록12173: [2023-03-28 row] [2021-09-14 row] ...

→ 조건에 맞는 row가 모든 블록에 흩어져 있음
→ 12,183건을 찾기 위해 12,173블록을 전부 뒤져야 함
```