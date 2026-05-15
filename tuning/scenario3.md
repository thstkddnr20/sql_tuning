# 조건절 데이터 가공 여부에 따른 인덱스 사용 확인

조건절의 인덱스 컬럼에 함수를 적용하여 데이터를 가공할 경우 인덱스를 제대로 활용하지 못하는 것을 확인한다.
`create index idx_member_email on member (email);`로 member의 email에 대해서 인덱스를 생성한다.

## Step 1. 가공 X
`select name from member where email = 'user443@example.com';`
email을 가공 없이 그대로 조건절에 넣고 사용자의 이름을 조회하는 쿼리이다.

```
--------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_member_email on member  (cost=0.41..8.43 rows=1 width=13) (actual time=0.043..0.045 rows=1 loops=1)
   Index Cond: ((email)::text = 'user443@example.com'::text)
 Planning Time: 0.114 ms
 Execution Time: 0.070 ms
(4 rows)
```

## Step 2. 인덱스 컬럼 가공
`select name from member where lower(email) = 'user443@example.com';`
조건절의 인덱스 컬럼인 email을 lower() 함수로 가공하였다.

```
-------------------------------------------------------------------------------------------------------
 Seq Scan on member  (cost=0.00..1266.00 rows=250 width=13) (actual time=0.417..25.904 rows=1 loops=1)
   Filter: (lower((email)::text) = 'user443@example.com'::text)
   Rows Removed by Filter: 49999
 Planning Time: 0.146 ms
 Execution Time: 25.941 ms
(5 rows)
```

## Step 3. 인덱스 컬럼이 아닌 상수 값 가공
`select name from member where email = lower('user443@EXAMPLE.COM');`
조건절의 입력 데이터를 lower() 함수로 가공하였다.

```
--------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_member_email on member  (cost=0.41..8.43 rows=1 width=13) (actual time=0.030..0.032 rows=1 loops=1)
   Index Cond: ((email)::text = 'user443@example.com'::text)
 Planning Time: 0.092 ms
 Execution Time: 0.047 ms
(4 rows)
```

## 정리
컬럼 자체가 변형되는 `WHERE 가공(컬럼) = 값` 형태는 B-Tree 인덱스의 정렬 구조를 그대로 사용하기 어렵다.
반면에 `WHERE 컬럼 = 가공(상수값)`의 형태는 인덱스 컬럼이 그대로 유지되므로 인덱스 구조를 사용할 수 있다.

인덱스 컬럼을 가공하면 DB입장에서는 가공을 해봐야 조건과 맞는지 확인할 수 있다.
그래서 일반적으로 row 읽기, 가공, 조건 확인 절차를 반복하여 Seq Scan이 일어나게 된다.

추가적으로 SARGable(Search ARGument ABLE)이라는 용어도 있다<br>
`관계형 데이터베이스(RDBMS)에서 WHERE 절이나 JOIN 조건이 인덱스를 효과적으로 활용하여 빠른 속도로 데이터를 조회할 수 있는 형태의 쿼리를 의미합니다`