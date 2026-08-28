CREATE TABLE edge (f INTEGER, t INTEGER);

CREATE VIEW reach_set AS
WITH RECURSIVE reach(f, t) AS (
  SELECT f, t FROM edge
  UNION
  SELECT r.f, e.t FROM reach r JOIN edge e ON r.t = e.f
)
SELECT f, t FROM reach;

CREATE VIEW reach_counts_set AS
SELECT f, COUNT(*) AS cnt FROM reach_set GROUP BY f;

CREATE VIEW reach_max_set AS
SELECT f, MAX(t) AS mx FROM reach_set GROUP BY f;

CREATE VIEW reach_big_set AS
SELECT f, cnt FROM reach_counts_set WHERE cnt >= 3;
