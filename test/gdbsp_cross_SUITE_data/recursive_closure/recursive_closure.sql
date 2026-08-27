CREATE TABLE edge (f INTEGER, t INTEGER);

CREATE VIEW reach_set AS
WITH RECURSIVE reach(f, t) AS (
  SELECT f, t FROM edge
  UNION
  SELECT r.f, e.t FROM reach r JOIN edge e ON r.t = e.f
)
SELECT f, t FROM reach;
