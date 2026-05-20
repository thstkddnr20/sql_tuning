# INCLUDE 인덱스 활용한 튜닝

include 인덱스를 생성하는 방법은 다음과 같다.<br>
`create 인덱스이름 on 테이블 (컬럼1) include (컬럼2)`<br>
PostgreSQL과 SQL Server에 있는 기능이다.

쿼리: `select price, stock from product where price >= 400000;`

## Step 1. price에 인덱스, INCLUDE X
`create index idx_product_price on product (price);`

```
---------------------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on product  (cost=27.94..137.19 rows=2020 width=8) (actual time=0.075..0.442 rows=2020 loops=1)
   Recheck Cond: (price >= 400000)
   Heap Blocks: exact=84
   ->  Bitmap Index Scan on idx_product_price  (cost=0.00..27.43 rows=2020 width=0) (actual time=0.057..0.058 rows=2020 loops=1)
         Index Cond: (price >= 400000)
 Planning Time: 0.074 ms
 Execution Time: 0.524 ms
(7 rows)
```

## Step 2. price에 인덱스가 있고 price를 INCLUDE
`create index idx_product_price_include_stock on product (price) include (stock);`

```
-----------------------------------------------------------------------------------------------------------------------------------------------------
 Index Only Scan using idx_product_price_include_stock on product  (cost=0.29..63.63 rows=2020 width=8) (actual time=0.014..0.136 rows=2020 loops=1)
   Index Cond: (price >= 400000)
   Heap Fetches: 0
 Planning Time: 0.052 ms
 Execution Time: 0.187 ms
(5 rows)
```

## 정리
1. Step 1은 INCLUDE를 사용하지 않아 stock값을 알아오기 위해 I/O가 발생하였다.
2. Step 2에서는 stock 값을 INCLUDE 하여 커버링 인덱스처럼 사용할 수 있게 되었다. Index Only Scan.

그럼 왜 INCLUDE를 사용하는가? 그냥 `create index idx_product_price_stock on product(price, stock);`으로 복합 인덱스 생성하면 되는거 아닌가?
1. INCLUDE를 사용하면 price만 브랜치에 걸리게 하고 리프 노드에는 stock도 같이 저장하게 하도록 하므로 브랜치의 크기가 감소한다. (복합 인덱스라면 price, stock으로 분기)
2. 브랜치가 가벼워져 브랜치 재정렬 비용이 감소하므로 인덱스의 유지 비용이 낮아진다
3. 결론적으로 인덱스 탐색 조건에는 쓰이지 않지만, 조회 시 자주 함께 select 되는 컬럼을 INCLUDE에 넣어 Heap 접근(Random I/O)을 없애는 것이 목적이다.