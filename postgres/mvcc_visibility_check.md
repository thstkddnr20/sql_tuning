# PostgreSQL Visibility Check Rules — 10가지 규칙 실전 테스트

AI를 활용하여 테스트케이스를 작성했습니다.  
> 참고: https://www.interdb.jp/pg/pgsql05/06.html  
> 필수 확장: `pageinspect` (tuple 내부 확인용)

---

## 사전 준비 (Setup)

```sql
-- 확장 설치 (superuser 필요)
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- 테스트 테이블 생성
DROP TABLE IF EXISTS visibility_test;
CREATE TABLE visibility_test (
    id      INT PRIMARY KEY,
    label   TEXT,
    note    TEXT
);

-- 헬퍼 뷰: 튜플 헤더 + 트랜잭션 상태를 한 번에 확인
CREATE OR REPLACE VIEW v_tuple_info AS
SELECT
    lp                                           AS line_ptr,
    t_xmin                                       AS xmin,
    t_xmax                                       AS xmax,
    pg_xact_status(t_xmin::text::xid8)           AS xmin_status,   -- xid → xid8
    CASE WHEN t_xmax = 0 THEN 'INVALID'
         ELSE pg_xact_status(t_xmax::text::xid8)                   -- xid → xid8
        END                                          AS xmax_status,
    t_infomask::bit(16)                          AS infomask,
        (t_infomask & x'0100'::int) > 0             AS xmin_committed,
    (t_infomask & x'0200'::int) > 0             AS xmin_aborted
FROM heap_page_items(get_raw_page('visibility_test', 0));
```

### 유용한 헬퍼 쿼리 모음

```sql
-- 현재 트랜잭션 ID
SELECT pg_current_xact_id();           -- 현재 세션의 XID

-- 현재 스냅샷 (xmin:xmax:xip_list)
SELECT pg_current_snapshot();          -- 예: 500:503:501,502

-- 스냅샷 파싱
SELECT
    pg_snapshot_xmin(pg_current_snapshot()) AS snap_xmin,   -- 가장 오래된 활성 XID
    pg_snapshot_xmax(pg_current_snapshot()) AS snap_xmax,   -- 다음 할당될 XID
    pg_snapshot_xip(pg_current_snapshot())  AS snap_xip;    -- 현재 활성 XID 목록

-- 특정 XID의 상태 확인
SELECT pg_xact_status('500'::xid);     -- 'committed' | 'aborted' | 'in progress' | NULL

-- 특정 XID가 스냅샷에서 "활성(active)" 상태인지 확인
SELECT pg_snapshot_xip(pg_current_snapshot()) @> ARRAY['500'::xid8];
-- 또는
SELECT '500'::xid8 = ANY(pg_snapshot_xip(pg_current_snapshot()));

-- 튜플 헤더 직접 조회
SELECT lp, t_xmin, t_xmax, t_infomask::bit(16)
FROM heap_page_items(get_raw_page('visibility_test', 0));
```

---

## 규칙 분류 요약

| 규칙 | t_xmin 상태 | 조건 | 결과 |
|------|------------|------|------|
| Rule 1 | ABORTED | — | **Invisible** |
| Rule 2 | IN_PROGRESS | t_xmin = current_txid ∧ t_xmax = INVALID | **Visible** |
| Rule 3 | IN_PROGRESS | t_xmin = current_txid ∧ t_xmax ≠ INVALID | **Invisible** |
| Rule 4 | IN_PROGRESS | t_xmin ≠ current_txid | **Invisible** |
| Rule 5 | COMMITTED | t_xmin이 스냅샷에서 active | **Invisible** |
| Rule 6 | COMMITTED | t_xmax = INVALID 또는 t_xmax ABORTED | **Visible** |
| Rule 7 | COMMITTED | t_xmax IN_PROGRESS ∧ t_xmax = current_txid | **Invisible** |
| Rule 8 | COMMITTED | t_xmax IN_PROGRESS ∧ t_xmax ≠ current_txid | **Visible** |
| Rule 9 | COMMITTED | t_xmax COMMITTED ∧ t_xmax이 스냅샷에서 active | **Visible** |
| Rule 10 | COMMITTED | t_xmax COMMITTED ∧ t_xmax이 스냅샷에서 not active | **Invisible** |

---

## Rule 1 — t_xmin ABORTED → Invisible

**시나리오:** INSERT 후 ROLLBACK한 튜플은 누구에게도 보이지 않는다.

```
흐름: Session 1: BEGIN → INSERT → ROLLBACK
      Session 2: SELECT → 0 rows (invisible)
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS my_xid;
-- 예: 500

INSERT INTO visibility_test VALUES (1, 'rule1', 'xmin will be ABORTED');

-- 롤백 전 자기 자신에게는 보임 (Rule 2)
SELECT * FROM visibility_test WHERE id = 1;
-- 결과: 1 row (자신의 미커밋 insert는 Rule 2로 visible)

ROLLBACK;  -- ← t_xmin(500)의 상태가 ABORTED로 기록됨
```

### Session 2 (ROLLBACK 이후 실행)

```sql
-- [Session 2]
SELECT * FROM visibility_test WHERE id = 1;
-- 결과: 0 rows ← Rule 1: t_xmin ABORTED → Invisible

-- 내부 확인: 튜플 자체는 페이지에 남아 있음
SELECT lp, t_xmin, t_xmax, pg_xact_status(t_xmin::text::xid8) AS xmin_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmin IS NOT NULL;
-- 튜플은 존재하지만 xmin_status = 'aborted'
-- → VACUUM 전까지 페이지에 dead tuple로 남음

-- XID 상태 직접 확인
SELECT pg_xact_status('500'::xid8);  -- 'aborted'
```

### 검증 포인트

```sql
-- VACUUM 후 dead tuple 제거 확인
VACUUM visibility_test;
SELECT * FROM heap_page_items(get_raw_page('visibility_test', 0));
-- lp_dead = 1 로 마킹되거나 사라짐
```

---

## Rule 2 — t_xmin IN_PROGRESS, 자신의 INSERT, t_xmax INVALID → Visible

**시나리오:** 같은 트랜잭션에서 INSERT한 튜플은 커밋 전에도 자기 자신에게 보인다.

```
흐름: Session 1: BEGIN → INSERT → SELECT (visible!)
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS my_xid;
-- 예: 501

INSERT INTO visibility_test VALUES (2, 'rule2', 'own uncommitted insert');

-- 커밋하지 않았지만 자기 자신에게는 보임
SELECT * FROM visibility_test WHERE id = 2;
-- 결과: 1 row ← Rule 2: t_xmin IN_PROGRESS, t_xmin = current_txid, t_xmax = INVALID

-- 스냅샷 확인 (IN_PROGRESS 상태)
SELECT pg_xact_status('501'::xid8);
-- 'in progress'

-- 튜플 헤더 확인
SELECT lp, t_xmin, t_xmax, pg_xact_status(t_xmin::text::xid8) AS xmin_status
FROM heap_page_items(get_raw_page('visibility_test', 0));
-- t_xmax = 0 (INVALID), xmin_status = 'in progress'

COMMIT;
```

### Session 2 (Session 1 BEGIN 이후, COMMIT 이전에 실행)

```sql
-- [Session 2] Session 1이 아직 COMMIT하지 않은 상태에서 실행
SELECT * FROM visibility_test WHERE id = 2;
-- 결과: 0 rows ← Rule 4: t_xmin IN_PROGRESS, t_xmin ≠ current_txid → Invisible
-- (Rule 2와 대비됨)
```

---

## Rule 3 — t_xmin IN_PROGRESS, 자신의 INSERT 후 DELETE/UPDATE → Invisible

**시나리오:** 같은 트랜잭션에서 INSERT 후 바로 DELETE하면, 그 튜플은 자기 자신에게도 보이지 않는다.

```
흐름: Session 1: BEGIN → INSERT → DELETE → SELECT (invisible!)
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS my_xid;
-- 예: 502

INSERT INTO visibility_test VALUES (3, 'rule3', 'insert then delete in same txn');

-- DELETE 전: 보임 (Rule 2)
SELECT * FROM visibility_test WHERE id = 3;
-- 결과: 1 row

-- 같은 트랜잭션에서 DELETE
DELETE FROM visibility_test WHERE id = 3;

-- DELETE 후: t_xmax가 current_txid(502)로 세팅됨
SELECT * FROM visibility_test WHERE id = 3;
-- 결과: 0 rows ← Rule 3: t_xmin IN_PROGRESS, t_xmax ≠ INVALID → Invisible

-- 튜플 헤더 확인
SELECT lp, t_xmin, t_xmax,
       pg_xact_status(t_xmin::text::xid8) AS xmin_status,
       pg_xact_status(t_xmax::text::xid8) AS xmax_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmin::text = '502';
-- t_xmin = 502 (IN_PROGRESS), t_xmax = 502 (IN_PROGRESS)
-- → t_xmax = current_txid이고 ≠ INVALID → Rule 3

ROLLBACK;
```

---

## Rule 4 — t_xmin IN_PROGRESS, 다른 트랜잭션 → Invisible

**시나리오:** 아직 커밋되지 않은 다른 세션의 INSERT는 보이지 않는다. (더티 리드 방지)

```
흐름: Session 1: BEGIN → INSERT (커밋 안 함)
      Session 2: SELECT → 0 rows (invisible)
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS s1_xid;
-- 예: 503

INSERT INTO visibility_test VALUES (4, 'rule4', 'other session uncommitted');

-- Session 1은 자기 자신에게 보임 (Rule 2)
SELECT * FROM visibility_test WHERE id = 4;
-- 결과: 1 row

-- ← 여기서 Session 2로 전환 (아직 COMMIT하지 않음)
```

### Session 2 (Session 1 COMMIT 이전에 실행)

```sql
-- [Session 2]
SELECT pg_current_xact_id() AS s2_xid;
-- 예: 504

SELECT * FROM visibility_test WHERE id = 4;
-- 결과: 0 rows ← Rule 4: t_xmin(503) IN_PROGRESS, t_xmin ≠ current_txid(504) → Invisible

-- 스냅샷으로 확인
SELECT pg_current_snapshot();
-- 503이 xip 목록에 있음을 확인

SELECT pg_xact_status('503'::xid8);
-- 'in progress'
```

### Session 1 (커밋 후)

```sql
-- [Session 1]
COMMIT;

-- [Session 2] 커밋 이후 다시 조회
SELECT * FROM visibility_test WHERE id = 4;
-- 결과: 1 row ← Rule 6으로 전환: t_xmin COMMITTED, t_xmax INVALID → Visible
```

---

## Rule 5 — t_xmin COMMITTED, 스냅샷에서 active → Invisible

**시나리오:** REPEATABLE READ에서 스냅샷을 찍은 시점에 진행 중이던 트랜잭션이 나중에 커밋해도, 해당 데이터는 보이지 않는다.

```
흐름: Session 2: BEGIN (XID 획득, 스냅샷에 기록됨)
      Session 1: BEGIN REPEATABLE READ → 스냅샷 획득 (Session 2의 XID가 xip에 포함)
      Session 2: INSERT → COMMIT
      Session 1: SELECT → 0 rows (invisible) ← Rule 5
```

### Session 2

```sql
-- [Session 2] 먼저 트랜잭션 시작 (XID 획득)
BEGIN;

SELECT pg_current_xact_id() AS s2_xid;
-- 예: 505
-- ← 여기서 Session 1로 전환
```

### Session 1

```sql
-- [Session 1] REPEATABLE READ로 시작 → 스냅샷 고정
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- ← 다시 Session 2로 전환
```

### Session 2 (INSERT 후 COMMIT)

```sql
-- [Session 2]
INSERT INTO visibility_test VALUES (5, 'rule5', 'committed after S1 snapshot');
COMMIT;

SELECT pg_xact_status('505'::xid8);
-- 'committed'  ← 커밋 완료됨
```

### Session 1 (스냅샷 고정 후 조회)

```sql
-- [Session 1] 스냅샷은 이미 찍힘
SELECT * FROM visibility_test WHERE id = 5;
-- 결과: 0 rows ← Rule 5: t_xmin(505) COMMITTED but active in snapshot → Invisible

COMMIT;

-- 트랜잭션 종료 후 새 쿼리: 새 스냅샷 적용
SELECT * FROM visibility_test WHERE id = 5;
-- 결과: 1 row ← 이제 Rule 6 적용: t_xmin COMMITTED, 스냅샷에서 inactive → Visible
```

---

## Rule 6 — t_xmin COMMITTED, t_xmax INVALID or ABORTED → Visible

**시나리오:** 정상 커밋된 행이고 삭제/갱신이 없거나 삭제가 ROLLBACK됨. 가장 일반적인 케이스.

```
흐름 A (t_xmax INVALID): 단순 INSERT + COMMIT
흐름 B (t_xmax ABORTED): DELETE 후 ROLLBACK
```

### 흐름 A — t_xmax INVALID

```sql
-- [Session 1]
BEGIN;
INSERT INTO visibility_test VALUES (6, 'rule6a', 'simple committed row');
COMMIT;

-- [Session 2]
SELECT * FROM visibility_test WHERE id = 6;
-- 결과: 1 row ← Rule 6: t_xmin COMMITTED, t_xmax = 0(INVALID) → Visible

-- 튜플 헤더 확인
SELECT lp, t_xmin, t_xmax,
       pg_xact_status(t_xmin::text::xid8) AS xmin_status,
       CASE WHEN t_xmax = 0 THEN 'INVALID' END AS xmax_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmin IS NOT NULL
ORDER BY lp DESC LIMIT 1;
-- t_xmax = 0 (INVALID) → Rule 6
```

### 흐름 B — t_xmax ABORTED

```sql
-- [Session 1] DELETE 후 ROLLBACK
BEGIN;

SELECT pg_current_xact_id() AS s1_xid;
-- 예: 510

DELETE FROM visibility_test WHERE id = 6;

ROLLBACK;  -- ← t_xmax(510)의 상태가 ABORTED

-- [Session 2]
SELECT * FROM visibility_test WHERE id = 6;
-- 결과: 1 row ← Rule 6: t_xmin COMMITTED, t_xmax(510) ABORTED → Visible

SELECT pg_xact_status('510'::xid8);
-- 'aborted'

-- 튜플 헤더 확인
SELECT lp, t_xmin, t_xmax,
       pg_xact_status(t_xmin::text::xid8) AS xmin_status,
       pg_xact_status(t_xmax::text::xid8) AS xmax_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmax = 510;
-- xmin_status = 'committed', xmax_status = 'aborted' → Rule 6
```

---

## Rule 7 — t_xmin COMMITTED, t_xmax IN_PROGRESS = current_txid → Invisible

**시나리오:** 내가 DELETE한 행은, 커밋 전에도 나 자신에게는 보이지 않는다.

```
흐름: 커밋된 행 준비
      Session 1: BEGIN → DELETE → SELECT (invisible!)
```

### 사전 준비

```sql
INSERT INTO visibility_test VALUES (7, 'rule7', 'will be deleted by own txn')
ON CONFLICT (id) DO NOTHING;
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS my_xid;
-- 예: 511

DELETE FROM visibility_test WHERE id = 7;

-- t_xmax = 511 (= current_txid), IN_PROGRESS
SELECT * FROM visibility_test WHERE id = 7;
-- 결과: 0 rows ← Rule 7: t_xmin COMMITTED, t_xmax IN_PROGRESS, t_xmax = current_txid → Invisible

-- 튜플 헤더 확인
SELECT lp, t_xmin, t_xmax,
       pg_xact_status(t_xmin::text::xid8) AS xmin_status,
       pg_xact_status(t_xmax::text::xid8) AS xmax_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmax = 511;
-- xmin_status = 'committed', xmax_status = 'in progress', t_xmax = my_xid → Rule 7

COMMIT;
```

---

## Rule 8 — t_xmin COMMITTED, t_xmax IN_PROGRESS ≠ current_txid → Visible

**시나리오:** 다른 세션이 DELETE 중인 행은, 그 DELETE가 커밋되기 전까지 나에게는 여전히 보인다.

```
흐름: 커밋된 행 준비
      Session 1: BEGIN → DELETE (커밋 안 함)
      Session 2: SELECT → 1 row (visible!) ← Rule 8
```

### 사전 준비

```sql
INSERT INTO visibility_test VALUES (8, 'rule8', 'being deleted by other session')
ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS s1_xid;
-- 예: 512

DELETE FROM visibility_test WHERE id = 8;
-- t_xmax = 512, IN_PROGRESS

-- ← Session 2로 전환 (아직 COMMIT하지 않음)
```

### Session 2

```sql
-- [Session 2]
SELECT pg_current_xact_id() AS s2_xid;
-- 예: 513

SELECT * FROM visibility_test WHERE id = 8;
-- 결과: 1 row ← Rule 8: t_xmin COMMITTED, t_xmax(512) IN_PROGRESS, t_xmax ≠ current_txid(513) → Visible

-- 튜플 헤더 확인
SELECT lp, t_xmin, t_xmax,
       pg_xact_status(t_xmin::text::xid8) AS xmin_status,
       pg_xact_status(t_xmax::text::xid8) AS xmax_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmax = 512;
-- xmin_status = 'committed', xmax_status = 'in progress', t_xmax(512) ≠ s2_xid(513) → Rule 8
```

### Session 1 (커밋 후)

```sql
-- [Session 1]
COMMIT;

-- [Session 2] 커밋 후 재조회
SELECT * FROM visibility_test WHERE id = 8;
-- 결과: 0 rows ← Rule 10 적용: t_xmax(512) COMMITTED, 스냅샷에서 inactive → Invisible
```

---

## Rule 9 — t_xmin COMMITTED, t_xmax COMMITTED, 스냅샷에서 active → Visible

**시나리오:** REPEATABLE READ에서 스냅샷 찍은 후에 다른 세션이 DELETE+COMMIT해도, 스냅샷 기준으로는 그 삭제가 보이지 않으므로 행이 여전히 visible.

```
흐름: 커밋된 행 준비
      Session 2: BEGIN (XID 획득)
      Session 1: BEGIN REPEATABLE READ → 스냅샷 획득 (Session 2의 XID가 xip에 포함)
      Session 2: DELETE → COMMIT
      Session 1: SELECT → 1 row (visible!) ← Rule 9
```

### 사전 준비

```sql
INSERT INTO visibility_test VALUES (9, 'rule9', 'deleted after S1 snapshot')
ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;
```

### Session 2

```sql
-- [Session 2] 먼저 트랜잭션 시작
BEGIN;

SELECT pg_current_xact_id() AS s2_xid;
-- 예: 514

-- ← Session 1로 전환
```

### Session 1

```sql
-- [Session 1] REPEATABLE READ로 스냅샷 고정
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- ← Session 2로 전환
```

### Session 2 (DELETE 후 COMMIT)

```sql
-- [Session 2]
DELETE FROM visibility_test WHERE id = 9;
-- t_xmax = 514

COMMIT;

SELECT pg_xact_status('514'::xid8);
-- 'committed' ← t_xmax가 이제 COMMITTED 상태
```

### Session 1 (조회)

```sql
-- [Session 1] 스냅샷은 고정됨
SELECT * FROM visibility_test WHERE id = 9;
-- 결과: 1 row ← Rule 9: t_xmax(514) COMMITTED but active in snapshot → Visible!

COMMIT;

-- 새 트랜잭션: Rule 10 적용
SELECT * FROM visibility_test WHERE id = 9;
-- 결과: 0 rows ← Rule 10: t_xmax COMMITTED, 스냅샷에서 inactive → Invisible
```

---

## Rule 10 — t_xmin COMMITTED, t_xmax COMMITTED, 스냅샷에서 not active → Invisible

**시나리오:** 이미 커밋된 DELETE라면, 이후에 시작한 어떤 트랜잭션에서도 해당 행은 보이지 않는다.

```
흐름: Session 1: DELETE → COMMIT
      Session 2: (커밋 이후 시작) SELECT → 0 rows (invisible)
```

### 사전 준비

```sql
INSERT INTO visibility_test VALUES (10, 'rule10', 'permanently deleted')
ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;
```

### Session 1

```sql
-- [Session 1]
BEGIN;

SELECT pg_current_xact_id() AS s1_xid;
-- 예: 515

DELETE FROM visibility_test WHERE id = 10;
COMMIT;

SELECT pg_xact_status('515'::xid8);
-- 'committed'
```

### Session 2 (Session 1 COMMIT 이후 시작)

```sql
-- [Session 2]
BEGIN;

SELECT * FROM visibility_test WHERE id = 10;
-- 결과: 0 rows ← Rule 10: t_xmax(515) COMMITTED, 스냅샷에서 inactive → Invisible

-- 튜플 헤더 확인 (dead tuple이 VACUUM 전까지 남아있음)
SELECT lp, t_xmin, t_xmax,
       pg_xact_status(t_xmin::text::xid8) AS xmin_status,
       pg_xact_status(t_xmax::text::xid8) AS xmax_status
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmax = 515;
-- xmin_status = 'committed', xmax_status = 'committed', t_xmax not in snapshot → Rule 10

COMMIT;
```

---

## 통합 검증 쿼리

### 모든 튜플 상태 한 번에 확인

```sql
-- pageinspect로 전체 페이지 튜플 상태 조회
SELECT
    lp,
    t_xmin,
    t_xmax,
    pg_xact_status(t_xmin::text::xid8)                       AS xmin_status,
    CASE WHEN t_xmax = 0 THEN 'INVALID'
         ELSE pg_xact_status(t_xmax::text::xid8)
        END                                                       AS xmax_status,
    CASE
        WHEN pg_xact_status(t_xmin::text::xid8) = 'aborted'
            THEN 'Rule 1: Invisible (xmin aborted)'
        WHEN pg_xact_status(t_xmin::text::xid8) = 'in progress'
            AND t_xmax = 0
            THEN 'Rule 2/4: Visible only to xmin txn'
        WHEN pg_xact_status(t_xmin::text::xid8) = 'in progress'
            AND t_xmax != 0
            THEN 'Rule 3/4: Invisible'
        WHEN pg_xact_status(t_xmin::text::xid8) = 'committed'
            AND (t_xmax = 0 OR pg_xact_status(t_xmax::text::xid8) = 'aborted')
            THEN 'Rule 6: Visible'
        WHEN pg_xact_status(t_xmin::text::xid8) = 'committed'
            AND pg_xact_status(t_xmax::text::xid8) = 'in progress'
            THEN 'Rule 7/8: Depends on current_txid vs t_xmax'
        WHEN pg_xact_status(t_xmin::text::xid8) = 'committed'
            AND pg_xact_status(t_xmax::text::xid8) = 'committed'
            THEN 'Rule 9/10: Depends on snapshot'
        ELSE 'Unknown'
        END                                                       AS probable_rule
FROM heap_page_items(get_raw_page('visibility_test', 0))
WHERE t_xmin IS NOT NULL
ORDER BY lp;
```