-- =============================================================
-- SQL 튜닝 실습 스키마 (PostgreSQL 16)
-- 인덱스는 튜닝 실습 과정에서 직접 추가
-- =============================================================

-- -------------------------------------------------------------
-- 1. category  |  코드성 소규모 테이블 (~30건)
-- -------------------------------------------------------------
CREATE TABLE category (
  category_id   SMALLSERIAL      NOT NULL,
  name          VARCHAR(50)      NOT NULL,
  parent_id     SMALLINT         NULL,
  PRIMARY KEY (category_id)
);

COMMENT ON TABLE  category              IS '카테고리 (대분류/소분류)';
COMMENT ON COLUMN category.parent_id   IS '대분류는 NULL';


-- -------------------------------------------------------------
-- 2. member  |  중간 규모 테이블 (5만건)
--    grade: A=VIP B=Gold C=Silver D=일반
-- -------------------------------------------------------------
CREATE TABLE member (
  member_id     SERIAL           NOT NULL,
  name          VARCHAR(30)      NOT NULL,
  email         VARCHAR(100)     NOT NULL,
  grade         CHAR(1)          NOT NULL,
  region        VARCHAR(10)      NOT NULL,
  joined_at     DATE             NOT NULL,
  PRIMARY KEY (member_id)
);

COMMENT ON TABLE  member            IS '회원';
COMMENT ON COLUMN member.grade      IS 'A=VIP B=Gold C=Silver D=일반';


-- -------------------------------------------------------------
-- 3. product  |  중간 규모 테이블 (1만건)
--    status: Y=판매중 N=판매중지
-- -------------------------------------------------------------
CREATE TABLE product (
  product_id    SERIAL           NOT NULL,
  name          VARCHAR(100)     NOT NULL,
  category_id   SMALLINT         NOT NULL,
  price         INTEGER          NOT NULL,
  stock         INTEGER          NOT NULL DEFAULT 0,
  status        CHAR(1)          NOT NULL DEFAULT 'Y',
  created_at    TIMESTAMP        NOT NULL,
  PRIMARY KEY (product_id)
);

COMMENT ON TABLE  product           IS '상품';
COMMENT ON COLUMN product.status    IS 'Y=판매중 N=판매중지';


-- -------------------------------------------------------------
-- 4. orders  |  대용량 테이블 (20만건)
--    status: O=주문 P=결제완료 D=배송중 C=완료 X=취소
-- -------------------------------------------------------------
CREATE TABLE orders (
  order_id      SERIAL           NOT NULL,
  member_id     INTEGER          NOT NULL,
  status        CHAR(1)          NOT NULL,
  ordered_at    TIMESTAMP        NOT NULL,
  total_amount  INTEGER          NOT NULL,
  PRIMARY KEY (order_id)
);

COMMENT ON TABLE  orders            IS '주문';
COMMENT ON COLUMN orders.status     IS 'O=주문 P=결제완료 D=배송중 C=완료 X=취소';


-- -------------------------------------------------------------
-- 5. order_item  |  최대 용량 테이블 (60만건)
-- -------------------------------------------------------------
CREATE TABLE order_item (
  order_item_id BIGSERIAL        NOT NULL,
  order_id      INTEGER          NOT NULL,
  product_id    INTEGER          NOT NULL,
  qty           SMALLINT         NOT NULL,
  unit_price    INTEGER          NOT NULL,
  PRIMARY KEY (order_item_id)
);

COMMENT ON TABLE order_item IS '주문상세';
