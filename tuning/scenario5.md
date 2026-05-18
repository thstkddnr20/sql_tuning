# 복합 인덱스 컬럼 순서의 영향

복합 인덱스의 순서에 따른 실행 계획을 분석한다.
member 테이블 사용.

## Step 1. grade, region 순서로 인덱스 생성
인덱스: `create index idx_member_grade_region on member (grade, region);`

1. `select * from member where grade = 'A'`

    ```
    ---------------------------------------------------------------------------------------------------------------------------------------
     Bitmap Heap Scan on member  (cost=19.66..554.00 rows=1467 width=51) (actual time=0.213..0.910 rows=1500 loops=1)
       Recheck Cond: (grade = 'A'::bpchar)
       Heap Blocks: exact=510
       ->  Bitmap Index Scan on idx_member_grade_region  (cost=0.00..19.29 rows=1467 width=0) (actual time=0.117..0.118 rows=1500 loops=1)
             Index Cond: (grade = 'A'::bpchar)
     Planning Time: 0.087 ms
     Execution Time: 1.073 ms
    (7 rows)
    ```

2. `select * from member where grade = 'A' and region = '서울';`

    ```
    ------------------------------------------------------------------------------------------------------------------------------------
     Bitmap Heap Scan on member  (cost=8.05..508.37 rows=367 width=51) (actual time=0.074..0.379 rows=500 loops=1)
       Recheck Cond: ((grade = 'A'::bpchar) AND ((region)::text = '서울'::text))
       Heap Blocks: exact=252
       ->  Bitmap Index Scan on idx_member_grade_region  (cost=0.00..7.96 rows=367 width=0) (actual time=0.044..0.044 rows=500 loops=1)
             Index Cond: ((grade = 'A'::bpchar) AND ((region)::text = '서울'::text))
     Planning Time: 0.069 ms
     Execution Time: 0.412 ms
    (7 rows)
    ```

3. `select * from member where region = '서울';`

    ```
    ------------------------------------------------------------------------------------------------------------
     Seq Scan on member  (cost=0.00..1141.00 rows=12520 width=51) (actual time=0.012..6.284 rows=12500 loops=1)
       Filter: ((region)::text = '서울'::text)
       Rows Removed by Filter: 37500
     Planning Time: 0.084 ms
     Execution Time: 6.870 ms
    (5 rows)
    ```

4. `select * from member where region = '서울' and grade = 'A';`
    ```
    ------------------------------------------------------------------------------------------------------------------------------------
     Bitmap Heap Scan on member  (cost=8.05..508.37 rows=367 width=51) (actual time=0.112..0.406 rows=500 loops=1)
       Recheck Cond: ((grade = 'A'::bpchar) AND ((region)::text = '서울'::text))
       Heap Blocks: exact=252
       ->  Bitmap Index Scan on idx_member_grade_region  (cost=0.00..7.96 rows=367 width=0) (actual time=0.063..0.064 rows=500 loops=1)
             Index Cond: ((grade = 'A'::bpchar) AND ((region)::text = '서울'::text))
     Planning Time: 0.095 ms
     Execution Time: 0.454 ms
    (7 rows)
    ```

## Step 2. region, grade 순서로 인덱스 생성
인덱스: `create index idx_member_region_grade on member (region, grade);`

1. `select * from member where grade = 'A'`

   ```
   ----------------------------------------------------------------------------------------------------------------------------------------
    Bitmap Heap Scan on member  (cost=559.66..1093.99 rows=1467 width=51) (actual time=0.281..0.928 rows=1500 loops=1)
      Recheck Cond: (grade = 'A'::bpchar)
      Heap Blocks: exact=510
      ->  Bitmap Index Scan on idx_member_region_grade  (cost=0.00..559.29 rows=1467 width=0) (actual time=0.186..0.187 rows=1500 loops=1)
            Index Cond: (grade = 'A'::bpchar)
    Planning Time: 0.085 ms
    Execution Time: 1.022 ms
   (7 rows)
   ```

2. `select * from member where grade = 'A' and region = '서울';`

   ```
   ------------------------------------------------------------------------------------------------------------------------------------
    Bitmap Heap Scan on member  (cost=8.05..508.37 rows=367 width=51) (actual time=0.110..0.411 rows=500 loops=1)
      Recheck Cond: (((region)::text = '서울'::text) AND (grade = 'A'::bpchar))
      Heap Blocks: exact=252
      ->  Bitmap Index Scan on idx_member_region_grade  (cost=0.00..7.96 rows=367 width=0) (actual time=0.063..0.064 rows=500 loops=1)
            Index Cond: (((region)::text = '서울'::text) AND (grade = 'A'::bpchar))
    Planning Time: 0.094 ms
    Execution Time: 0.457 ms
   (7 rows)
   ```

3. `select * from member where region = '서울';`

   ```
   ------------------------------------------------------------------------------------------------------------------------------------------
    Bitmap Heap Scan on member  (cost=145.32..817.82 rows=12520 width=51) (actual time=0.233..1.264 rows=12500 loops=1)
      Recheck Cond: ((region)::text = '서울'::text)
      Heap Blocks: exact=516
      ->  Bitmap Index Scan on idx_member_region_grade  (cost=0.00..142.19 rows=12520 width=0) (actual time=0.175..0.176 rows=12500 loops=1)
            Index Cond: ((region)::text = '서울'::text)
    Planning Time: 0.051 ms
    Execution Time: 1.515 ms
   (7 rows)
   ```

4. `select * from member where region = '서울' and grade = 'A';`

   ```
   ------------------------------------------------------------------------------------------------------------------------------------
    Bitmap Heap Scan on member  (cost=8.05..508.37 rows=367 width=51) (actual time=0.112..0.476 rows=500 loops=1)
      Recheck Cond: (((region)::text = '서울'::text) AND (grade = 'A'::bpchar))
      Heap Blocks: exact=252
      ->  Bitmap Index Scan on idx_member_region_grade  (cost=0.00..7.96 rows=367 width=0) (actual time=0.063..0.064 rows=500 loops=1)
            Index Cond: (((region)::text = '서울'::text) AND (grade = 'A'::bpchar))
    Planning Time: 0.096 ms
    Execution Time: 0.526 ms
   (7 rows)
   ```

## 정리
1. Step 1에서 (grade, region) 인덱스가 생성된 상태에서 
   - grade만 단독 조건이 있거나
   - grade와 region이 and 조건으로 함께 있을때
   인덱스의 선행 컬럼인 grade에 조건이 존재하므로 Bitmap Index Scan이 발생하고 Seq Scan에 비해 성능이 향상된다.
2. region만 단독 조건이 있는 경우
   - 인덱스의 선행 컬럼인 grade에 조건이 없으므로 해당 인덱스를 활용할 수 없다.
   Seq Scan이 일어나며, 인덱스를 생성한 의미가 없어진다.
3. where 절에 조건이 나타나는 순서는 무관 (2번, 4번)
   - `where region = '서울' and grade = 'A'` 또는 `where grade = 'A' and region '서울'`모두 동일하게 인덱스를 탄다.
4. Step 2의 1번(region, grade 인덱스)에서 grade로 인덱스를 타는 이유는 옵티마이저가 Seq Scan보다 비용이 낮다고 판단했기 때문이다.
5. Step 2의 3번에서 인덱스를 탔지만, region = '서울' 조건에 걸리는 데이터가 많기 때문에 실행시간이 생각보다 높게 나왔다. (총 50000 유저중 12500 유저가 서울)