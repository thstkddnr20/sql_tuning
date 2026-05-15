-- =============================================================
-- SQL 튜닝 실습 데이터 생성 (PostgreSQL 16)
-- generate_series() 활용 → 깔끔하고 빠른 대용량 데이터 생성
-- =============================================================

-- =============================================================
-- 1. category  (30건: 대분류 5 + 소분류 25)
-- =============================================================
INSERT INTO category (name, parent_id) VALUES
  ('전자제품',      NULL),
  ('패션',          NULL),
  ('식품',          NULL),
  ('가구/인테리어', NULL),
  ('스포츠',        NULL);

INSERT INTO category (name, parent_id) VALUES
  ('스마트폰',  1), ('노트북',   1), ('태블릿',   1), ('이어폰',   1), ('카메라',   1),
  ('남성의류',  2), ('여성의류', 2), ('신발',     2), ('가방',     2), ('액세서리', 2),
  ('신선식품',  3), ('가공식품', 3), ('음료',     3), ('건강식품', 3), ('간식',     3),
  ('소파',      4), ('침대',     4), ('책상',     4), ('조명',     4), ('수납',     4),
  ('헬스',      5), ('아웃도어', 5), ('구기종목', 5), ('수영',     5), ('사이클',   5);


-- =============================================================
-- 2. member  (5만건)
--    grade 분포: D=60% C=25% B=12% A=3%
-- =============================================================
INSERT INTO member (name, email, grade, region, joined_at)
SELECT
  CONCAT('회원', LPAD((n + 1)::TEXT, 6, '0')),
  CONCAT('user', n + 1, '@example.com'),
  CASE
    WHEN n % 100 <  3 THEN 'A'
    WHEN n % 100 < 15 THEN 'B'
    WHEN n % 100 < 40 THEN 'C'
    ELSE                   'D'
  END,
  (ARRAY['서울','서울','경기','경기','부산','대구','인천','광주'])[( n % 8) + 1],
  '2019-01-01'::DATE + ((n * 7 + 3) % 1826) * INTERVAL '1 day'
FROM generate_series(0, 49999) AS s(n);


-- =============================================================
-- 3. product  (1만건)
--    category_id: 6~30 (소분류 25개)
--    status: Y=90% N=10%
-- =============================================================
INSERT INTO product (name, category_id, price, stock, status, created_at)
SELECT
  CONCAT('상품-', LPAD((n + 1)::TEXT, 5, '0')),
  6 + (n % 25),
  (1 + (n * 37 + 11) % 500) * 1000,
  (n * 13 + 7) % 200,
  CASE WHEN n % 10 = 0 THEN 'N' ELSE 'Y' END,
  '2019-01-01'::TIMESTAMP + ((n * 11 + 5) % 1826) * INTERVAL '1 day'
FROM generate_series(0, 9999) AS s(n);


-- =============================================================
-- 4. orders  (20만건)
--    status: C=50% D=20% P=15% O=10% X=5%
--    ordered_at: 2020-01-01 ~ 2023-12-31
-- =============================================================
INSERT INTO orders (member_id, status, ordered_at, total_amount)
SELECT
  1 + (n * 3 + 7) % 50000,
  CASE
    WHEN n % 20 <  1 THEN 'X'
    WHEN n % 20 <  3 THEN 'O'
    WHEN n % 20 <  6 THEN 'P'
    WHEN n % 20 < 10 THEN 'D'
    ELSE                   'C'
  END,
  '2020-01-01'::TIMESTAMP
    + ((n * 17 + 3) % 1461) * INTERVAL '1 day'
    + ((n * 23 + 5) % 86400) * INTERVAL '1 second',
  (1 + (n * 41 + 13) % 490) * 1000
FROM generate_series(0, 199999) AS s(n);


-- =============================================================
-- 5. order_item  (주문당 3건 → 60만건)
-- =============================================================
INSERT INTO order_item (order_id, product_id, qty, unit_price)
SELECT
  t.order_id,
  p.product_id,
  t.qty,
  p.price
FROM (
  SELECT
    o.order_id,
    1 + ABS((o.order_id::BIGINT * 1000003 + i) % 10000)::INTEGER AS product_id,
    1 + ABS((o.order_id::BIGINT * 7      + i * 31) % 5)::INTEGER AS qty
  FROM orders o
  CROSS JOIN generate_series(1, 3) AS s(i)
) t
JOIN product p ON p.product_id = t.product_id;


-- =============================================================
-- 통계 정보 갱신 (EXPLAIN BUFFERS 정확도 향상)
-- =============================================================
ANALYZE category;
ANALYZE member;
ANALYZE product;
ANALYZE orders;
ANALYZE order_item;


-- =============================================================
-- 데이터 검증
-- =============================================================
SELECT tbl, cnt FROM (
  SELECT 1 AS ord, 'category'   AS tbl, COUNT(*) AS cnt FROM category   UNION ALL
  SELECT 2,        'member',             COUNT(*)         FROM member     UNION ALL
  SELECT 3,        'product',            COUNT(*)         FROM product    UNION ALL
  SELECT 4,        'orders',             COUNT(*)         FROM orders     UNION ALL
  SELECT 5,        'order_item',         COUNT(*)         FROM order_item
) t ORDER BY ord;
