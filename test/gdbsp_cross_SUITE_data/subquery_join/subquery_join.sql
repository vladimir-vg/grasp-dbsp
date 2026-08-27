CREATE TABLE data (dept INTEGER, sal INTEGER);

CREATE VIEW with_max_set AS
  SELECT d.dept, d.sal, m.max_sal
  FROM data d
  JOIN (SELECT dept, MAX(sal) AS max_sal FROM data GROUP BY dept) m
    ON d.dept = m.dept;
