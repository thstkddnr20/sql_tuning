# pg_stat_statements

EXPLAIN ANALYZE는 특정 쿼리 하나를 직접 분석할 때 사용한다.
하지만 운영 환경에서는 "어떤 쿼리가 문제인지"를 먼저 찾아야 한다.

`pg_stat_statements`는 PostgreSQL에서 실행된 모든 쿼리의 실행 횟수, 총 소요 시간, 평균 시간 등을 누적해서 기록하는 확장 모듈이다.
이를 통해 전체 쿼리 중 어떤 것이 병목인지 파악할 수 있다.

---

## 사전 준비: 확장 활성화

`pg_stat_statements`는 기본적으로 비활성화되어 있다. 한 번만 설정하면 된다.

```sql
-- 확장 설치
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 설치 확인
SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';
```

```
-- 결과 기록
```

`postgresql.conf`에 아래 설정이 있어야 데이터가 수집된다.
Docker 환경이라면 `docker-compose.yml`의 command 옵션에 추가한다.

```
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
```

---

## 실험 1: pg_stat_statements 기본 구조 파악

### Step 1. 주요 컬럼 확인

```sql
SELECT
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
    LIMIT 5;
```

```
-- 결과 기록
```

주요 컬럼 의미:

| 컬럼 | 설명 |
|---|---|
| `query` | 실행된 쿼리 (파라미터는 `$1`, `$2`로 정규화됨) |
| `calls` | 누적 실행 횟수 |
| `total_exec_time` | 누적 총 실행 시간 (ms) |
| `mean_exec_time` | 평균 실행 시간 (ms) |
| `rows` | 누적 반환/영향 행 수 |

### Step 2. 통계 초기화 후 실험 쿼리 실행

기존에 쌓인 통계를 지우고 직접 쿼리를 실행해서 수집되는 과정을 확인한다.

```sql
-- 통계 초기화
SELECT pg_stat_statements_reset();

-- 실험용 쿼리 여러 번 실행
SELECT * FROM orders WHERE status = 'C';
SELECT * FROM orders WHERE status = 'C';
SELECT * FROM orders WHERE status = 'C';
SELECT COUNT(*) FROM order_item WHERE order_id = 1;
SELECT COUNT(*) FROM order_item WHERE order_id = 1;
```

```sql
-- 수집된 결과 확인
SELECT query, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
ORDER BY calls DESC;
```

```
                        query                        | calls |   total_exec_time   |    mean_exec_time    |  rows
-----------------------------------------------------+-------+---------------------+----------------------+--------
 SELECT * FROM orders WHERE status = $1              |     3 |           98.063062 |   32.687687333333336 | 300000
 SELECT COUNT(*) FROM order_item WHERE order_id = $1 |     2 | 0.05920500000000001 | 0.029602500000000004 |      2
 SELECT pg_stat_statements_reset()                   |     1 | 0.18194700000000003 |  0.18194700000000003 |      1
```

---

## 실험 2: 느린 쿼리 찾기

운영에서 가장 먼저 확인하는 것은 **평균 실행 시간이 긴 쿼리**다.

### Step 1. 통계 초기화 후 다양한 쿼리 실행

```sql
SELECT pg_stat_statements_reset();

-- 빠른 쿼리 (인덱스 사용)
SELECT * FROM member WHERE email = 'user1@example.com';
SELECT * FROM member WHERE email = 'user2@example.com';
SELECT * FROM member WHERE email = 'user3@example.com';

-- 느린 쿼리 (Seq Scan 유발)
SELECT * FROM orders o JOIN order_item oi ON o.order_id = oi.order_id WHERE o.status = 'C';
SELECT COUNT(*) FROM order_item;
```

### Step 2. 평균 실행 시간 기준 정렬

```sql
SELECT
    query,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(total_exec_time::numeric, 2) AS total_ms
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
    LIMIT 10;
```

```
                                           query                                           | calls | mean_ms | total_ms
-------------------------------------------------------------------------------------------+-------+---------+----------
 SELECT * FROM orders o JOIN order_item oi ON o.order_id = oi.order_id WHERE o.status = $1 |     1 |  230.50 |   230.50
 SELECT COUNT(*) FROM order_item                                                           |     1 |   10.92 |    10.92
 SELECT * FROM member WHERE email = $1                                                     |     3 |    0.11 |     0.33
 SELECT pg_stat_statements_reset()                                                         |     1 |    0.08 |     0.08
```

---

## 실험 3: 총 부하 기준으로 찾기

평균이 빠르더라도 **호출 횟수가 많으면** 총 부하가 클 수 있다.
`mean_exec_time`이 아닌 `total_exec_time` 기준으로 정렬하면 서버 전체에 가장 큰 영향을 주는 쿼리를 찾을 수 있다.

```sql
SELECT pg_stat_statements_reset();

-- 빠르지만 매우 자주 호출되는 쿼리 시뮬레이션
DO $$
BEGIN
FOR i IN 1..500 LOOP
        PERFORM * FROM member WHERE email = 'user' || i || '@example.com';
END LOOP;
END;
$$;

-- 느리지만 가끔 호출되는 쿼리
SELECT * FROM orders o JOIN order_item oi ON o.order_id = oi.order_id WHERE o.status = 'C';
```

### Step 1. mean_exec_time 기준 (건당 느린 쿼리)

```sql
SELECT
    query,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(total_exec_time::numeric, 2) AS total_ms
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 5;
```

```
                                           query                                           | calls | mean_ms | total_ms
-------------------------------------------------------------------------------------------+-------+---------+----------
 SELECT * FROM orders o JOIN order_item oi ON o.order_id = oi.order_id WHERE o.status = $1 |     1 |  224.98 |   224.98
 DO $$                                                                                    +|     1 |    8.99 |     8.99
 BEGIN                                                                                    +|       |         |
     FOR i IN 1..500 LOOP                                                                 +|       |         |
         PERFORM * FROM member WHERE email = 'user' || i || '@example.com';               +|       |         |
     END LOOP;                                                                            +|       |         |
 END;                                                                                     +|       |         |
 $$                                                                                        |       |         |
 SELECT pg_stat_statements_reset()                                                         |     1 |    0.14 |     0.14
 SELECT * FROM member WHERE email = $3 || i || $4                                          |   500 |    0.01 |     5.71
```

### Step 2. total_exec_time 기준 (전체 부하가 큰 쿼리)

```sql
SELECT
    query,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(total_exec_time::numeric, 2) AS total_ms
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;
```

```
                                           query                                           | calls | mean_ms | total_ms 
-------------------------------------------------------------------------------------------+-------+---------+----------
 SELECT * FROM orders o JOIN order_item oi ON o.order_id = oi.order_id WHERE o.status = $1 |     1 |  224.98 |   224.98
 DO $$                                                                                    +|     1 |    8.99 |     8.99
 BEGIN                                                                                    +|       |         | 
     FOR i IN 1..500 LOOP                                                                 +|       |         |
         PERFORM * FROM member WHERE email = 'user' || i || '@example.com';               +|       |         |
     END LOOP;                                                                            +|       |         |
 END;                                                                                     +|       |         |
 $$                                                                                        |       |         |
 SELECT * FROM member WHERE email = $3 || i || $4                                          |   500 |    0.01 |     5.71
 SELECT pg_stat_statements_reset()                                                         |     1 |    0.14 |     0.14
```

### 정리

두 정렬 결과를 비교하면 3, 4위 순서가 바뀐 것을 확인할 수 있다.

- `mean_exec_time` 기준: member 쿼리(0.01ms)가 reset(0.14ms)보다 낮음
- `total_exec_time` 기준: member 쿼리(5.71ms)가 reset(0.14ms)보다 높음

member 쿼리는 건당 0.01ms로 매우 빠르지만 500번 호출되어 총합 5.71ms가 됐다.
`mean_exec_time`만 봤다면 가장 무해한 쿼리처럼 보이지만, `total_exec_time`으로 보면 reset보다 40배 더 많은 부하를 주고 있다.

다만 이번 실험에서는 JOIN 쿼리(224ms)가 워낙 압도적이어서 대비가 약하게 느껴진다.
루프 횟수를 500에서 25,000으로 늘리면 member 쿼리의 total이 JOIN 수준에 근접해 역전 현상을 더 뚜렷하게 확인할 수 있다.

---

## 전체 정리

| 관점 | 정렬 기준 | 찾는 것 |
|---|---|---|
| 건당 느린 쿼리 | `mean_exec_time DESC` | 한 번 실행에 오래 걸리는 쿼리 |
| 서버 전체 부하 | `total_exec_time DESC` | 호출 횟수 × 시간이 가장 큰 쿼리 |
| 호출 빈도 | `calls DESC` | 가장 자주 실행되는 쿼리 |
