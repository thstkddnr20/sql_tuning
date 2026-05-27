# Write-Write Conflict(Lost Update) 해결

MVCC는  
1. Read vs Read
2. Read vs Write
3. Write vs Read

상황을 해결할 수 있지만, Write vs Write 상황을 해결하지 못한다.  
Snapshot 개념과 dead tuple이라는 개념이 있어, Snapshot 정보를 통해 지금까지 생성된 tuple 중 읽을 데이터를 찾는다.  
하지만 Write vs Write 상황에서는 다르다.

예를 들어 SELECT 후 애플리케이션에서 값을 계산한 뒤 UPDATE를 수행하는 경우,  
먼저 실행된 트랜잭션의 변경 사항이 뒤 트랜잭션에 의해 덮어써질 수 있다(Lost Update).

이를 방지하기 위해 PostgreSQL은 MVCC와 함께 tuple-level lock을 사용하여  
동시에 같은 row를 수정하지 못하도록 제어한다.

## 테스트 테이블 생성
```sql
CREATE TABLE lock_test (
    id BIGSERIAL PRIMARY KEY,
    balance INTEGER NOT NULL,
    version INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

INSERT INTO lock_test (balance) VALUES (100);
```

## 1. READ COMMITTED vs READ COMMITTED 테스트
```sql
-- 세션 1
BEGIN;

-- 세션 2
BEGIN;

-- 세션 1
update lock_test set version = 1 where id = 1;

-- 세션 2
-- 이미 세션 1이 락을 선점했기 때문에 이 쿼리는 바로 실행되지 않고 대기한다. 
update lock_test set version = 2 where id = 1;

-- 세션 1
-- 세션 1을 commit 시키니 세션 2의 update문이 실행된다.
COMMIT;

-- 세션 2
COMMIT;

-- 세션 1이 커밋을 마친 후, 세션 2은 새로 갱신된 committed tuple을 기준으로 update 문을 다시 실행한다.
```

## 2. READ COMMITTED vs REPEATABLE READ 테스트 1
```sql
-- 세션 1
BEGIN;

-- 세션 2
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- 세션 1
update lock_test set version = 3 where id = 1;

-- 세션 2
-- 이미 세션 1이 락을 선점했기 때문에 이 쿼리는 바로 실행되지 않고 대기한다. 
update lock_test set version = 4 where id = 1;

-- 세션 1
-- 세션 1이 COMMIT하니, 세션 2에서는 에러가 발생한다. ERROR:  could not serialize access due to concurrent update
COMMIT;

-- 세션 2
COMMIT;

SELECT * FROM lock_test;

-- 결과
id | balance | version |         created_at
----+---------+---------+----------------------------
  1 |     100 |       3 | 2026-05-27 05:38:19.830343
(1 row)
   
-- READ COMMITTED와 달리 REPEATABLE READ에서는 update 충돌을 제어한다.
```

## 3. READ COMMITTED vs REPEATABLE READ 테스트 2
```sql
-- 세션 1
BEGIN;

-- 세션 2
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- 세션 2
select * from lock_test where id = 1;

-- 세션 1 
update lock_test set version = 5 where id = 1;

-- 세션 1
COMMIT;

-- 세션 2
-- 세션 1이 commit되고 세션 2가 update를 시도하니 에러가 발생한다. ERROR:  could not serialize access due to concurrent update
update lock_test set version = 6 where id = 1;

-- 세션 2
COMMIT;

-- READ COMMITTED와 달리 REPEATABLE READ에서는 update 충돌을 제어한다.
```

## 정리
ww conflict 문제는 MVCC만으로 막을 수 없고, lock이 필요하다.  
READ COMMITTED와 REPEATABLE READ는 모두 lock을 사용하여 ww conflict를 막지만,  
REPEATABLE READ가 충돌을 더 엄격하게 제어한다. 