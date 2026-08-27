CREATE TABLE data (k INTEGER, a INTEGER);
CREATE TABLE excluded (k INTEGER);

CREATE VIEW kept_set AS
  SELECT k, a
  FROM data
  WHERE k NOT IN (SELECT k FROM excluded);
