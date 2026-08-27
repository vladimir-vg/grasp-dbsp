CREATE TABLE data (dept INTEGER, cat INTEGER, v INTEGER);

CREATE VIEW agg_set AS
  SELECT dept, cat, SUM(v) AS total, COUNT(*) AS cnt, MIN(v) AS lo, MAX(v) AS hi
  FROM data
  GROUP BY dept, cat
