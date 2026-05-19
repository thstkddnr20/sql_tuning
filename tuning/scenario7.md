# 데이터 양에 따른 인덱스 효율 한계 2

시나리오 6에서는 모든 데이터(총 10000건)가 조건에 부합할때 Seq Scan을 선택함을 확인했다.
member 테이블(총 50000건)의 조건에 걸리는 데이터의 양을 조절하여 인덱스를 타는지 안타는지 실험하겠다.

인덱스: `create index idx_member_email on member (email);`

`email < 'user150'`조건 (5555/50000) 부터 1씩 늘려가면서 임계점을 확인해보겠다.


## 결과

```
-----------------------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on member  (cost=421.16..1125.46 rows=15064 width=51) (actual time=1.080..1.778 rows=14888 loops=1)
   Recheck Cond: ((email)::text < 'user234'::text)
   Heap Blocks: exact=157
   ->  Bitmap Index Scan on idx_member_email  (cost=0.00..417.40 rows=15064 width=0) (actual time=1.064..1.064 rows=14888 loops=1)
         Index Cond: ((email)::text < 'user234'::text)
 Planning Time: 0.071 ms
 Execution Time: 2.109 ms
(7 rows)
```

```
------------------------------------------------------------------------------------------------------------
 Seq Scan on member  (cost=0.00..1141.00 rows=15165 width=51) (actual time=0.009..4.276 rows=14999 loops=1)
   Filter: ((email)::text < 'user235'::text)
   Rows Removed by Filter: 35001
 Planning Time: 0.066 ms
 Execution Time: 4.618 ms
(5 rows)
```

## 정리

실험 결과, 옵티마이저는 전체 데이터의 약 30%를 기점으로 실행 계획을 변경함을 알 수 있다.

- `email < 'user234'` (약 29.7%, 14,888건): Bitmap Heap Scan 선택 (2.109 ms)
- `email < 'user235'` (약 30.0%, 14,999건): Seq Scan 선택 (4.618 ms)

결론:
1. 임계점(Tipping Point): 데이터의 선택도가 일정 수준(여기서는 약 30%)을 넘어가면, 인덱스를 통해 랜덤 I/O를 발생시키는 것보다 테이블 전체를 순차적으로 읽는 Seq Scan이 더 효율적이라고 판단한다.
2. 튜닝 포인트: 튜닝 시 단순히 인덱스 유무가 아니라, 실제 조회되는 데이터의 양과 비율을 예측하여 인덱스가 원하는대로 사용되는지 확인한 후, 전략을 세워야한다.

## 추가 실험
PostgreSQL에서 `create index idx_member_email on member (email);` 인덱스를 걸었지만 like 조건으로 비교를해보니 인덱스를 올바르게 사용하지 못하는 것을 발견했다.

예시 쿼리<br>
`select * from member where email like 'user1111%';` 이 쿼리는 50000명의 유저중 단 11명의 데이터를 불러오는 쿼리이다.<br> 
또한 user1111로 시작하는 이메일을 대상으로 찾는 쿼리이므로 인덱스의 사용을 기대했지만 Seq Scan이 발생했다.

```
-----------------------------------------------------------------------------------------------------
 Seq Scan on member  (cost=0.00..1141.00 rows=5 width=51) (actual time=0.065..2.289 rows=11 loops=1)
   Filter: ((email)::text ~~ 'user1111%'::text)
   Rows Removed by Filter: 49989
 Planning Time: 0.058 ms
 Execution Time: 2.299 ms
(5 rows)
```

50000건의 데이터를 읽고 49989개의 행을 버리는 것을 볼 수 있다.

패턴 전용 인덱스를 생성해야 like 절 인덱스 사용을 확인할 수 있었다.<br>
`CREATE INDEX idx_member_email_pattern ON member (email varchar_pattern_ops);`

```
-----------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_member_email_pattern on member  (cost=0.41..8.44 rows=5 width=51) (actual time=0.018..0.022 rows=11 loops=1)
   Index Cond: (((email)::text ~>=~ 'user1111'::text) AND ((email)::text ~<~ 'user1112'::text))
   Filter: ((email)::text ~~ 'user1111%'::text)
 Planning Time: 0.091 ms
 Execution Time: 0.033 ms
(5 rows)
```

AI의 대답:<br>
기본 인덱스는 우측의 국가별 정렬 규칙으로 사전을 만들어 둡니다. 
그래서 컴퓨터가 LIKE로 글자 앞부분을 잘라서 찾으려고 하면, 
규칙이 너무 복잡해서 사전을 못 읽고 포기(Full Scan)해 버립니다.
varchar_pattern_ops는 강제로 좌측의 단순 바이트 순서로 사전을 새로 만듭니다. 
글자가 바이트 순서대로 칼같이 모여있기 때문에, 컴퓨터가 LIKE 검색을 할 때 막힘없이 인덱스를 사용할 수 있게 됩니다.

## 궁금한 점
optimizer의 실행계획은 사실 사용자의 응답 속도를 향상시키려는 목적도 있지만, 부담을 전제로 계산하는 거 아닐까? 
그래서 데이터가 약 30%가 되었을 때 seq scan을 선택한 이유도 seq scan은 시간이 조금 더 걸리지만 random I/O로 인한 실행 비용이 크니까 그런거 아닐까?

맞다. PostgreSQL 기본 설정에 `seq_page_cost`와 `random_page_cost`라는 비용부터 알아보자.
1. seq_page_cost(기본 값 1.0): 플래너가 디스크에서 페이지를 연속적으로 순차 읽기 할때 드는 비용의 기준점
2. random_page_cost(기본 값 4.0): 인덱스 스캔처럼 디스크의 여러 위치를 무작위로 비순차 읽기 할때 드는 가상의 비용

이 4배 차이나 나는 기본 값은 과거 하드디스크 시절의 물리적 헤더 이동속도를 기준으로 설계된 보수적인 값이다.<br>
대다수 서버가 사용하는 ssd 환경에서는 순차 읽기와 무작위 읽기 속도 차이가 거의 없다. 그래서 인덱스를 더 적극적으로 활용하도록 이 값을 조정하여 사용한다.

`ALTER SYSTEM SET random_page_cost = 1.1;`로 random_page_cost를 1.1로 낮추고 다시 테스트 해봤다.

```
-------------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_member_email on member  (cost=0.41..1049.15 rows=22499 width=51) (actual time=0.063..3.251 rows=22222 loops=1)
   Index Cond: ((email)::text < 'user300'::text)
 Planning Time: 0.079 ms
 Execution Time: 3.771 ms
(4 rows)
```

이때는 약 절반의 데이터 (22222/50000)까지도 인덱스를 사용하는 것을 확인했다. 플래너가 비용 계산 시 들어가는 가중치가 낮아졌으므로 가능한 일이다.

