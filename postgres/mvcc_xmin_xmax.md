# xmin과 xmax - MVCC 기초

postgresql은 xmin과 xmax라는 숨겨진 컬럼을 통해 MVCC를 구현하였다.  
각 튜플이 어느 트랜잭션에서 생성되고 삭제됐는지를 기록함으로써 여러 트랜잭션이 동시에 같은 데이터를 읽고 써도 충돌 없이 동작하게 한다.

실습 테이블 생성
```sql
CREATE TABLE mvcc_test (
    id SERIAL PRIMARY KEY,
    name VARCHAR(30) NOT NULL,
    price INTEGER NOT NULL
);
```

## 숨겨진 컬럼: xmin, xmax
select문에 xmin, xmax을 넣으면 조회 가능하다.
```sql
INSERT INTO mvcc_test (name, price) VALUES ('사과', 1000), ('바나나', 2000), ('포도', 3000);

SELECT *, xmin, xmax FROM mvcc_test;
```

결과
```
 id |  name  | price | xmin | xmax
----+--------+-------+------+------
  1 | 사과   |  1000 |  816 |    0
  2 | 바나나 |  2000 |  816 |    0
  3 | 포도   |  3000 |  816 |    0
```

## xmin
이 튜플을 생성한 트랜잭션 ID를 적는 공간이다.  
모든 튜플은 어떤 트랜잭션에 의해서 생성되기 때문에 xmin은 필수 값이다.

```sql
BEGIN;

-- 현재 트랜잭션 ID 확인
SELECT txid_current();

INSERT INTO mvcc_test (name, price) VALUES ('수박', 5000);

COMMIT;
```

결과
```sql
SELECT *, xmin, xmax FROM mvcc_test WHERE name = '수박';

 id | name | price | xmin | xmax
----+------+-------+------+------
  4 | 수박 |  5000 |  817 |    0
```

## xmax
튜플을 삭제(또는 갱신)한 트랜잭션 ID이다.  
xmax = 0이면 아직 삭제되지 않은 유효한 튜플이다.

```sql
-- 세션 2
BEGIN;

-- 세션 2
SELECT * FROM mvcc_test;

id |  name  | price
----+--------+-------
  1 | 사과   |  1000
  2 | 바나나 |  2000
  3 | 포도   |  3000
  5 | 수박   |  5000

-- 세션 1
BEGIN;

-- 세션 1
SELECT txid_current();

-- 세션 1
DELETE FROM mvcc_test WHERE name = '수박';

-- 세션 2
SELECT *, xmin, xmax FROM mvcc_test WHERE name = '수박';

-- 결과
id | name | price | xmin | xmax
----+------+-------+------+------
  5 | 수박 |  5000 |  819 |  820
   
-- 세션 1
COMMIT;
   
-- 세션 2
SELECT *, xmin, xmax FROM mvcc_test WHERE name = '수박';

-- 결과 
id | name | price | xmin | xmax
----+------+-------+------+------
```

## UPDATE문 실행
INSERT문과 DELETE문을 사용할 때 xmin과 xmax의 값을 확인했다.  
이번에는 UPDATE문을 사용할 때 xmin과 xmax를 확인해보겠다.

```sql
-- 세션 1
BEGIN;

-- 세션 2
BEGIN;

-- 세션 1
SELECT txid_current(); -- txid_current = 836;

-- 세션 1
UPDATE mvcc_test SET price = 4000 WHERE name = '사과';

-- 세션 2
-- 아래 쿼리는 CREATE EXTENSION pageinspect; 익스텐션 생성을 통해 확인 가능하다.
SELECT t_xmin, t_xmax, t_ctid, t_infomask FROM heap_page_items(get_raw_page('mvcc_test', 0));

-- 결과
t_xmin | t_xmax | t_ctid | t_infomask 
--------+--------+--------+------------
    836 |      0 | (0,4)  |      10242
        |        |        |
        |        |        |
        |        |        |
        |        |        |
    832 |    836 | (0,4)  |       8962
```

맨 아래 튜플이 dead tuple이 되고 xmin 836, xmax 0인 새로운 live 튜플이 생성되었다.  
즉 update문은 delete와 insert의 작업이 동시에 일어나는 것임을 확인할 수 있다.

## 정리
PostgreSQL은 xmin과 xmax라는 개념을 사용하여 튜플에 대한 버전 관리를 한다.

1. INSERT
   - live tuple을 만든다.
   - insert를 사용한 트랜잭션 id가 xmin으로 들어간다.
   - 새로 생성된 튜플이기 때문에 xmax값이 0이다.
2. DELETE
   - dead tuple을 만든다.
   - delete를 사용한 트랜잭션 id가 xmax값으로 들어간다.
3. UPDATE
   - live tuple, dead tuple을 모두 만든다.
   - INSERT + DELETE 방식으로 동작한다.
   - 기존 튜플의 xmax = UPDATE 트랜잭션 ID (dead)
   - 새 튜플의 xmin  = UPDATE 트랜잭션 ID (live)
   - 즉, 같은 트랜잭션 ID가 기존 튜플의 xmax와 새 튜플의 xmin에 동시에 들어간다.

내가 읽을 수 있는 컬럼인지 아닌지, 내 트랜잭션 id와 xmin, xmax를 비교하여 가시성 체크(visibility check)를 한다.
이후에 가시성 체크에 대해서 더 자세하게 알아보겠다.