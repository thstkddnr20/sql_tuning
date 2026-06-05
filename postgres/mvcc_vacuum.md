# VACUUM과 Dead Tuple

PostgreSQL에서 UPDATE나 DELETE를 실행하면 기존 행이 즉시 삭제되지 않는다.
MVCC 구조상 다른 트랜잭션이 이전 버전을 읽을 수 있어야 하기 때문이다.
더 이상 아무 트랜잭션도 참조하지 않는 이 오래된 행들을 **Dead Tuple**이라고 부른다.

VACUUM은 이 Dead Tuple을 정리하는 PostgreSQL의 청소 작업이다.

---

## 실험 1: Dead Tuple이 쌓이고 VACUUM으로 정리되는 과정

### 사전 준비

실험 도중 PostgreSQL이 자동으로 VACUUM을 실행하면 결과를 관찰하기 어렵다.
`autovacuum_enabled = false`로 자동 실행을 막아두고 시작한다.

```sql
ALTER TABLE orders SET (autovacuum_enabled = false);
```

### Step 1. 현재 상태 확인

`pg_stat_user_tables`는 테이블별 통계를 제공한다.
`n_live_tup`은 살아있는 행, `n_dead_tup`은 Dead Tuple 수다.

```sql
SELECT n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

```
 n_live_tup | n_dead_tup
------------+------------
     200000 |          0
```

### Step 2. 대량 UPDATE 후 확인

UPDATE는 기존 행에 xmax를 기록하고 새 행을 삽입하는 방식으로 동작한다.
기존 행은 Dead Tuple이 되어 테이블에 남는다.

```sql
UPDATE orders SET status = 'Z' WHERE status = 'C';

SELECT n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

```
 n_live_tup | n_dead_tup
------------+------------
     200000 |     100000
```

### Step 3. VACUUM 후 확인

```sql
VACUUM orders;

SELECT n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

```
 n_live_tup | n_dead_tup
------------+------------
     200000 |          0
```

### 정리

PostgreSQL에서 UPDATE는 기존 행을 수정하지 않는다. 기존 행에 xmax를 기록해 "삭제 예정"으로 표시하고, 새 버전의 행을 별도로 삽입한다. 이 때 기존 행이 Dead Tuple이 된다.

Step 2에서 `status = 'C'`인 행을 UPDATE했을 때 n_dead_tup이 크게 늘어난 것은 이 때문이다. UPDATE한 건수만큼 Dead Tuple이 생겼다.

VACUUM을 실행하면 더 이상 어떤 트랜잭션도 참조하지 않는 Dead Tuple을 찾아 제거하고, 해당 공간을 재사용 가능 상태로 표시한다. Step 3에서 n_dead_tup이 0으로 돌아온 것을 확인할 수 있다.

autovacuum이 비활성화된 상태에서는 VACUUM을 수동으로 실행하기 전까지 Dead Tuple이 계속 쌓인다. 운영 환경에서 autovacuum을 끄면 안 되는 이유다.

---

## 실험 2: VACUUM vs VACUUM FULL — 디스크 공간 회수

VACUUM이 Dead Tuple을 정리했다면, 그 공간은 OS에 반환될까?
일반 VACUUM과 VACUUM FULL의 차이가 여기서 나타난다.

- **VACUUM**: Dead Tuple을 정리하고 그 공간을 "다음 INSERT/UPDATE에 재사용 가능"으로 표시한다.
  파일 크기 자체는 줄어들지 않는다.
- **VACUUM FULL**: 테이블 전체를 새 파일로 다시 작성한다. 파일 크기가 실제로 줄어든다.
  단, 작업하는 동안 테이블에 Lock이 걸려 다른 쿼리가 모두 대기한다.

```
[DELETE 후]
파일: [  live  ][  dead  ][  live  ][  dead  ]

[VACUUM 후]
파일: [  live  ][ 재사용 ][  live  ][ 재사용 ]  ← 크기 그대로

[VACUUM FULL 후]
파일: [  live  ][  live  ]                       ← 크기 줄어듦
```

### 사전 준비

실험 전 데이터를 원래 상태로 되돌린다.

```sql
-- 실험 1에서 변경한 status를 원래대로 복구
UPDATE orders SET status = 'C' WHERE status = 'Z';
VACUUM orders;

-- autovacuum 비활성화 유지
ALTER TABLE orders SET (autovacuum_enabled = false);
```

### Step 1. 초기 테이블 크기 기록

```sql
SELECT pg_size_pretty(pg_relation_size('orders'));
```

```
 pg_size_pretty
----------------
 17 MB
```

### Step 2. 대량 DELETE 후 크기 확인

```sql
DELETE FROM orders WHERE status = 'D';

SELECT pg_size_pretty(pg_relation_size('orders'));
```

```
 pg_size_pretty
----------------
 17 MB
```

### Step 3. VACUUM 후 크기 확인

```sql
VACUUM orders;

SELECT pg_size_pretty(pg_relation_size('orders'));
```

```
 pg_size_pretty
----------------
 17 MB
```

### Step 4. VACUUM FULL 후 크기 확인

```sql
VACUUM FULL orders;

SELECT pg_size_pretty(pg_relation_size('orders'));
```

```
 pg_size_pretty
----------------
 9416 kB
```

### 정리

Step 1 → 2에서 대량 DELETE를 해도 파일 크기가 줄지 않은 것은, 삭제된 행이 Dead Tuple로 파일 안에 그대로 남아 있기 때문이다.

Step 2 → 3에서 VACUUM을 실행해도 파일 크기가 변하지 않은 것은, VACUUM이 Dead Tuple 공간을 "재사용 가능"으로 표시할 뿐 파일을 재작성하지 않기 때문이다. 이 공간은 이후 INSERT나 UPDATE가 들어올 때 먼저 채워진다.

Step 3 → 4에서 VACUUM FULL을 실행하면 테이블 전체를 새 파일로 다시 작성하면서 비어있는 공간 없이 live tuple만 남긴다. 파일 크기가 실제로 줄어드는 것을 확인할 수 있다.

VACUUM FULL은 실행 중 테이블 전체에 Lock을 걸기 때문에 그 시간 동안 해당 테이블에 대한 모든 읽기·쓰기 쿼리가 대기한다. 그래서 운영 환경에서는 거의 사용하지 않고, 대규모 일회성 삭제 이후 디스크 공간을 즉시 회수해야 할 때처럼 꼭 필요한 상황에서만 사용한다.

---

## 전체 정리

| 실험 | 핵심 관찰 포인트 |
|---|---|
| 실험 1 | UPDATE/DELETE 후 n_dead_tup 증가, VACUUM 후 0으로 감소 |
| 실험 2 | VACUUM은 파일 크기를 줄이지 않음, VACUUM FULL만 실제 공간 회수 |
