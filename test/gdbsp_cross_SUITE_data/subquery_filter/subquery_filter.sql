CREATE TABLE data (dept INTEGER, sal INTEGER);

CREATE VIEW high_dept_set AS
  SELECT dept, total
  FROM (SELECT dept, SUM(sal) AS total FROM data GROUP BY dept) t
  WHERE t.total > 100;
