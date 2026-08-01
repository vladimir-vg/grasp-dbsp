CREATE TABLE left (k INTEGER, a INTEGER);
CREATE TABLE right (k INTEGER, b INTEGER);

CREATE VIEW joined_set AS
  SELECT l.k, l.a, r.b
  FROM left l JOIN right r ON l.k = r.k
