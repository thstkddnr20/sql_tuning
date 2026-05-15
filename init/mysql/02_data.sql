-- =============================================================
-- SQL 튜닝 실습 데이터 생성
-- 총 데이터: category 30건 / member 5만 / product 1만
--           orders 20만 / order_item 60만
-- =============================================================

USE tuning;

-- 대용량 INSERT 성능 향상 설정
SET FOREIGN_KEY_CHECKS = 0;
SET unique_checks     = 0;
SET autocommit        = 0;

-- =============================================================
-- 시퀀스 헬퍼 테이블 (10^5 = 100,000행 숫자 시퀀스)
-- =============================================================
CREATE TABLE _n10 (
                      n TINYINT UNSIGNED NOT NULL,
                      PRIMARY KEY (n)
);
INSERT INTO _n10 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

-- a~e 5단계 크로스조인 → 0~99,999 시퀀스
CREATE TABLE _seq AS
SELECT a.n
           + b.n * 10
           + c.n * 100
           + d.n * 1000
           + e.n * 10000 AS n
FROM _n10 a, _n10 b, _n10 c, _n10 d, _n10 e;

ALTER TABLE _seq ADD PRIMARY KEY (n);


-- =============================================================
-- 1. category  (30건: 대분류 5 + 소분류 25)
-- =============================================================
INSERT INTO category (name, parent_id) VALUES
                                           ('전자제품',     NULL),
                                           ('패션',         NULL),
                                           ('식품',         NULL),
                                           ('가구/인테리어', NULL),
                                           ('스포츠',       NULL);

INSERT INTO category (name, parent_id) VALUES
                                           -- 전자제품 소분류 (parent=1)
                                           ('스마트폰',   1), ('노트북',   1), ('태블릿',   1), ('이어폰',   1), ('카메라',   1),
                                           -- 패션 소분류 (parent=2)
                                           ('남성의류',   2), ('여성의류', 2), ('신발',     2), ('가방',     2), ('액세서리', 2),
                                           -- 식품 소분류 (parent=3)
                                           ('신선식품',   3), ('가공식품', 3), ('음료',     3), ('건강식품', 3), ('간식',     3),
                                           -- 가구/인테리어 소분류 (parent=4)
                                           ('소파',       4), ('침대',     4), ('책상',     4), ('조명',     4), ('수납',     4),
                                           -- 스포츠 소분류 (parent=5)
                                           ('헬스',       5), ('아웃도어', 5), ('구기종목', 5), ('수영',     5), ('사이클',   5);

COMMIT;


-- =============================================================
-- 2. member  (5만건)
--    grade 분포: D(일반)=60% C(Silver)=25% B(Gold)=12% A(VIP)=3%
--    region: 서울·경기 비중 높게
-- =============================================================
INSERT INTO member (name, email, grade, region, joined_at)
SELECT
    CONCAT('회원', LPAD(n + 1, 6, '0'))                            AS name,
    CONCAT('user', n + 1, '@example.com')                          AS email,
    CASE
        WHEN MOD(n, 100) <  3 THEN 'A'   -- VIP   3%
        WHEN MOD(n, 100) < 15 THEN 'B'   -- Gold 12%
        WHEN MOD(n, 100) < 40 THEN 'C'   -- Silver 25%
        ELSE                       'D'   -- 일반   60%
        END                                                            AS grade,
    ELT(1 + MOD(n, 8),
        '서울','서울','경기','경기','부산','대구','인천','광주')       AS region,
    DATE_ADD('2019-01-01',
             INTERVAL MOD(n * 7 + 3, 1826) DAY)                   AS joined_at  -- 2019~2023
FROM _seq
WHERE n < 50000;

COMMIT;


-- =============================================================
-- 3. product  (1만건)
--    소분류 category_id: 6~30 (25개)
--    status: 판매중(Y) 90% / 판매중지(N) 10%
-- =============================================================
INSERT INTO product (name, category_id, price, stock, status, created_at)
SELECT
    CONCAT('상품-', LPAD(n + 1, 5, '0'))                           AS name,
    6 + MOD(n, 25)                                                 AS category_id,
    -- 가격: 1,000원 ~ 500,000원 (천원 단위)
    (1 + MOD(n * 37 + 11, 500)) * 1000                            AS price,
    MOD(n * 13 + 7, 200)                                           AS stock,
    IF(MOD(n, 10) = 0, 'N', 'Y')                                  AS status,
    DATE_ADD('2019-01-01',
             INTERVAL MOD(n * 11 + 5, 1826) DAY)                  AS created_at
FROM _seq
WHERE n < 10000;

COMMIT;


-- =============================================================
-- 4. orders  (20만건)
--    _seq는 0~99,999(10만행)까지만 존재하므로
--    n 과 n+100000 두 구간을 UNION ALL 로 합쳐 20만행 확보
--    status 분포: C(완료)=50% D(배송중)=20% P(결제완료)=15%
--                O(주문)=10%   X(취소)=5%
--    ordered_at: 2020-01-01 ~ 2023-12-31 (4년)
-- =============================================================
INSERT INTO orders (member_id, status, ordered_at, total_amount)
SELECT
    1 + MOD(n * 3 + 7, 50000)                                     AS member_id,
    CASE
        WHEN MOD(n, 20) <  1 THEN 'X'
        WHEN MOD(n, 20) <  3 THEN 'O'
        WHEN MOD(n, 20) <  6 THEN 'P'
        WHEN MOD(n, 20) < 10 THEN 'D'
        ELSE                       'C'
        END                                                            AS status,
    DATE_ADD(
            DATE_ADD('2020-01-01', INTERVAL MOD(n * 17 + 3, 1461) DAY),
            INTERVAL MOD(n * 23 + 5, 86400) SECOND
  )                                                              AS ordered_at,
    (1 + MOD(n * 41 + 13, 490)) * 1000                            AS total_amount
FROM (
         SELECT n           FROM _seq   -- 0 ~ 99,999
         UNION ALL
         SELECT n + 100000  FROM _seq   -- 100,000 ~ 199,999
     ) AS seq200k;

COMMIT;


-- =============================================================
-- 5. order_item  (주문당 3건 → 60만건)
--    product_id는 subquery로 계산 후 JOIN → 실제 price 참조
-- =============================================================
INSERT INTO order_item (order_id, product_id, qty, unit_price)
SELECT
    t.order_id,
    p.product_id,
    t.qty,
    p.price                                                        AS unit_price
FROM (
         SELECT
             o.order_id                                                   AS order_id,
             -- 1~10000 범위 product_id (시드를 다르게 줘서 세 행이 다른 상품 참조)
             1 + MOD(ABS(o.order_id * 1000003 + i.n * 999983), 10000)   AS product_id,
             1 + MOD(ABS(o.order_id * 7 + i.n * 31), 5)                 AS qty
         FROM orders o
                  CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3) i
     ) t
         JOIN product p ON p.product_id = t.product_id;

COMMIT;


-- =============================================================
-- 헬퍼 테이블 정리
-- =============================================================
DROP TABLE _n10;
DROP TABLE _seq;

-- 설정 복구
SET FOREIGN_KEY_CHECKS = 1;
SET unique_checks     = 1;
SET autocommit        = 1;


-- =============================================================
-- 데이터 확인 쿼리 (초기화 완료 후 검증용)
-- =============================================================
SELECT '=== 테이블별 데이터 건수 ===' AS '';
SELECT 'category'   AS tbl, COUNT(*) AS cnt FROM category
UNION ALL
SELECT 'member',               COUNT(*) FROM member
UNION ALL
SELECT 'product',              COUNT(*) FROM product
UNION ALL
SELECT 'orders',               COUNT(*) FROM orders
UNION ALL
SELECT 'order_item',           COUNT(*) FROM order_item;