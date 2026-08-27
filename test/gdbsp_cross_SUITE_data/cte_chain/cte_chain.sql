CREATE TABLE data (dept INTEGER, sal INTEGER);

CREATE VIEW high_dept_set AS
WITH dept_totals AS (
  SELECT dept, SUM(sal) AS total FROM data GROUP BY dept
),
big_totals AS (
  SELECT dept, total FROM dept_totals WHERE total >= 200
)
SELECT dept, total FROM big_totals;
