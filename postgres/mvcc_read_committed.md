# PostgreSQL의 MVCC와 Read Committed 격리 수준

## MVCC란?
Multi-Version Concurrency Control의 약자로 데이터를 수정할 때 기존 데이터를 지우지 않고 새로운 버전을 추가하는 방식으로 동작

```text
UPDATE 발생 시

기존 방식 (Lock 기반):
  100,000 → 200,000으로 덮어씀
  다른 세션은 UPDATE가 끝날 때까지 대기

MVCC 방식:
  버전 1: balance=100,000  (이전 버전, 아직 유효)
  버전 2: balance=200,000  (새 버전, 커밋 전)
  → 다른 세션은 버전 1을 읽으면 됨
  → 블로킹 없음
```

## 테이블 설정
```sql
CREATE TABLE accounts (
    account_id INT PRIMARY KEY,
    name VARCHAR(20),
    balance INT
);

INSERT INTO accounts VALUES (1, '김철수', 100000);
```

## 실험 1 - MVCC 기본 동작 확인
두 개의 세션을 열고 순서대로 실행한다.

```sql
-- 세션 A
BEGIN;
UPDATE accounts SET balance = 200000 WHERE account_id = 1;
-- 결과: -
```

```sql
-- 세션 B
SELECT balance FROM accounts WHERE account_id = 1;
-- 결과: 100000
```

```sql
-- 세션 A
COMMIT;
-- 결과: -
```

```sql
-- 세션 B
SELECT balance FROM accounts WHERE account_id = 1;
-- 결과: 200000
```

세션 A가 UPDATE 중이어도 세션 B는 블로킹 없이 읽는다.  
MVCC가 이전 버전을 유지하기 때문이고, Dirty Read를 방지한다 (커밋되지 않은 데이터는 보이지 않는다).

## 실험 2 - Read Committed의 특성 (Non-Repeatable Read)

Read Committed는 SELECT마다 새로운 스냅샷을 찍는다. 같은 트랜잭션 안에서도 SELECT 시점에 따라 결과가 달라질 수 있다.

```sql
-- 세션 B
BEGIN;
SELECT balance FROM accounts WHERE account_id = 1;
-- 결과: 200000
```

```sql
-- 세션 A
BEGIN;
UPDATE accounts SET balance = 300000 WHERE account_id = 1;
COMMIT;
-- 결과: -
```

```sql
-- 세션 B
SELECT balance FROM accounts WHERE account_id = 1;
COMMIT;
-- 결과: 300000
```

## 실험 3 - Repeatable Read와 비교

```sql
-- 세션 B
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM accounts WHERE account_id = 1;
-- 결과: 300000
```

```sql
-- 세션 A
BEGIN;
UPDATE accounts SET balance = 400000 WHERE account_id = 1;
COMMIT;
-- 결과: -
```

```sql
-- 세션 B
SELECT balance FROM accounts WHERE account_id = 1;
COMMIT;
-- 결과: 300000
```

Repeatable Read는 트랜잭션 시작 시점의 스냅샷을 고정한다.  
그래서 중간에 다른 세션이 COMMIT해도 보이지 않는다.  
Non-Repeatable Read를 방지한다.  
대신 스냅샷이 오래될수록 Dead Tuple이 누적된다.

## 실험 4 - Dead Tuple 확인

```sql
-- 대량 UPDATE
UPDATE accounts SET balance = balance + 1;
UPDATE accounts SET balance = balance + 1;
UPDATE accounts SET balance = balance + 1;

-- Dead Tuple 확인
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'accounts';

-- 결과
-- relname  | n_live_tup | n_dead_tup 
-- ----------+------------+------------
-- accounts |          1 |          4
-- (1 row)
```

```sql
-- VACUUM으로 정리
VACUUM accounts;

-- 다시 확인
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'accounts';

-- 결과
-- relname  | n_live_tup | n_dead_tup 
-- ----------+------------+------------
--  accounts |          1 |          0
-- (1 row)
```