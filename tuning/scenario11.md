# random_page_cost와 플래너 오판

플래너는 비용 기반으로 실행 계획을 선택한다.  
이때 랜덤 I/O는 순차 I/O보다 비싸다고 가정하고 들어간다.  
```
seq_page_cost = 1.0 (기본값)
random_page_cost = 4.0 (기본값) <- HDD 시절 설계
```

이 random_page_cost 값이 4.0이면 플래너는 인덱스 탐색(Random I/O)를 과대평가하게 되고,  
Nested Loop보다 Seq Scan + Hash Join을 선호하는 방향으로 될 수 있다.

실제로는 데이터가 이미 shared_buffer에 캐싱되어 있거나, SSD 환경이라 랜덤과 순차의 I/O 속도 차이가 거의 없는 경우에  
플래너의 가정이 현실과 달라져서 잘못된 플랜이 선택된다.

사용 쿼리<br>
```sql
SELECT m.member_id, m.name, m.grade, o.order_id, o.ordered_at, o.total_amount
FROM member m
JOIN orders o ON o.member_id = m.member_id
WHERE m.grade = 'A';

create index idx_orders_member_id on orders (member_id);
create index idx_member_grade on member (grade);
```

## 기존 작동
```
--------------------------------------------------------------------------------------------------------------------------------------------
 Hash Join  (cost=573.41..4569.46 rows=6000 width=35) (actual time=0.506..17.599 rows=6000 loops=1)
   Hash Cond: (o.member_id = m.member_id)
   Buffers: shared hit=1984
   ->  Seq Scan on orders o  (cost=0.00..3471.00 rows=200000 width=20) (actual time=0.003..6.872 rows=200000 loops=1)
         Buffers: shared hit=1471
   ->  Hash  (cost=554.66..554.66 rows=1500 width=19) (actual time=0.495..0.497 rows=1500 loops=1)
         Buckets: 2048  Batches: 1  Memory Usage: 91kB
         Buffers: shared hit=513
         ->  Bitmap Heap Scan on member m  (cost=19.91..554.66 rows=1500 width=19) (actual time=0.076..0.395 rows=1500 loops=1)
               Recheck Cond: (grade = 'A'::bpchar)
               Heap Blocks: exact=510
               Buffers: shared hit=513
               ->  Bitmap Index Scan on idx_member_grade  (cost=0.00..19.54 rows=1500 width=0) (actual time=0.044..0.044 rows=1500 loops=1)
                     Index Cond: (grade = 'A'::bpchar)
                     Buffers: shared hit=3
 Planning:
   Buffers: shared hit=14
 Planning Time: 0.143 ms
 Execution Time: 17.762 ms
(19 rows)
```

## random_page_cost를 1.1로 낮춘 후
```
------------------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.71..3234.89 rows=6000 width=35) (actual time=0.016..4.233 rows=6000 loops=1)
   Buffers: shared hit=11013
   ->  Index Scan using idx_member_grade on member m  (cost=0.29..491.20 rows=1500 width=19) (actual time=0.010..0.434 rows=1500 loops=1)
         Index Cond: (grade = 'A'::bpchar)
         Buffers: shared hit=513
   ->  Index Scan using idx_orders_member_id on orders o  (cost=0.42..1.79 rows=4 width=20) (actual time=0.001..0.002 rows=4 loops=1500)
         Index Cond: (member_id = m.member_id)
         Buffers: shared hit=10500
 Planning:
   Buffers: shared hit=14
 Planning Time: 0.157 ms
 Execution Time: 4.408 ms
(12 rows)
```

## 정리
`set random_page_cost = 1.1`로 설정하였다. 여기서 1.1은 SSD 환경 권장 값이다.  
random_page_cost는 기본 값이 4.0이다. 이는 이전의 scenario7에서도 알아봤지만 과거 하드디스크 시절의 물리적 헤더 이동속도를 기준으로 설계된 보수적인 값이다.

플래너는 캐시 히트 여부를 모르고 하드웨어의 특성도 모르기 때문에 환경에 맞는 파라미터를 설정해줘야 올바른 판단을 한다. 