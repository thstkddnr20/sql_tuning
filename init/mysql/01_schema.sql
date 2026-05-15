-- =============================================================
-- SQL 튜닝 실습 스키마
-- 도메인: E-Commerce (카테고리 / 회원 / 상품 / 주문 / 주문상세)
-- =============================================================

USE tuning;

-- -------------------------------------------------------------
-- 1. category  |  코드성 소규모 테이블 (~30건)
--    - 대분류(parent_id IS NULL) / 소분류 2단계 구조
--    - Full Table Scan vs Index Scan 비교 실습에 활용
-- -------------------------------------------------------------
CREATE TABLE category (
  category_id   TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name          VARCHAR(50)      NOT NULL,
  parent_id     TINYINT UNSIGNED NULL     COMMENT '대분류는 NULL',
  PRIMARY KEY (category_id)
) COMMENT='카테고리 (대분류/소분류)';


-- -------------------------------------------------------------
-- 2. member  |  중간 규모 테이블 (5만건)
--    - grade 컬럼: 선택도 낮음  → 인덱스 효과 실습
--    - joined_at : 날짜 범위 스캔 실습
-- -------------------------------------------------------------
CREATE TABLE member (
  member_id     INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  name          VARCHAR(30)      NOT NULL,
  email         VARCHAR(100)     NOT NULL,
  grade         CHAR(1)          NOT NULL COMMENT 'A=VIP B=Gold C=Silver D=일반',
  region        VARCHAR(10)      NOT NULL,
  joined_at     DATE             NOT NULL,
  PRIMARY KEY (member_id),
  UNIQUE KEY  uk_member_email    (email)
) COMMENT='회원';


-- -------------------------------------------------------------
-- 3. product  |  중간 규모 테이블 (1만건)
--    - (status, price) 복합인덱스 → 복합인덱스 실습
--    - category_id : FK 성격의 컬럼 → NL Join 드라이빙 실습
-- -------------------------------------------------------------
CREATE TABLE product (
  product_id    INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  name          VARCHAR(100)     NOT NULL,
  category_id   TINYINT UNSIGNED NOT NULL,
  price         INT UNSIGNED     NOT NULL,
  stock         INT UNSIGNED     NOT NULL DEFAULT 0,
  status        CHAR(1)          NOT NULL DEFAULT 'Y' COMMENT 'Y=판매중 N=판매중지',
  created_at    DATETIME         NOT NULL,
  PRIMARY KEY (product_id)
) COMMENT='상품';


-- -------------------------------------------------------------
-- 4. orders  |  대용량 테이블 (20만건)
--    - member_id  : NL Join Inner 역할 실습
--    - ordered_at : 날짜 범위 스캔, 파티셔닝 실습
--    - (status, ordered_at) 복합인덱스 → 선두 컬럼 조건 실습
-- -------------------------------------------------------------
CREATE TABLE orders (
  order_id      INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  member_id     INT UNSIGNED     NOT NULL,
  status        CHAR(1)          NOT NULL COMMENT 'O=주문 P=결제완료 D=배송중 C=완료 X=취소',
  ordered_at    DATETIME         NOT NULL,
  total_amount  INT UNSIGNED     NOT NULL,
  PRIMARY KEY (order_id)
) COMMENT='주문';


-- -------------------------------------------------------------
-- 5. order_item  |  최대 용량 테이블 (60만건)
--    - order_id   : 집계/서브쿼리 실습 (주문당 3건)
--    - product_id : 상품별 판매 집계 실습
-- -------------------------------------------------------------
CREATE TABLE order_item (
  order_item_id BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  order_id      INT UNSIGNED     NOT NULL,
  product_id    INT UNSIGNED     NOT NULL,
  qty           TINYINT UNSIGNED NOT NULL,
  unit_price    INT UNSIGNED     NOT NULL,
  PRIMARY KEY (order_item_id)
) COMMENT='주문상세';
