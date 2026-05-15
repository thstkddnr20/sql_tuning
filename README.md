# SQL 튜닝 실습 환경

친절한 SQL 튜닝 학습을 위한 Docker 기반 PostgreSQL와 MySQL 실습 환경입니다.

## 테이블 구성

```
category   (    30건) ─ 코드성 소규모 테이블
member     ( 50,000건) ─ 중간 규모
product    ( 10,000건) ─ 중간 규모
orders     (200,000건) ─ 대용량
order_item (600,000건) ─ 최대 용량
```

### ERD 요약

```
category ──< product ──< order_item >── orders >── member
```
