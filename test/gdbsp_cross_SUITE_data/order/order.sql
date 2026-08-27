CREATE TABLE data (k INTEGER, v INTEGER);

CREATE VIEW ordered_seq AS
  SELECT k, v,
         RANK() OVER (ORDER BY k DESC) AS rank,
         ROW_NUMBER() OVER (ORDER BY k DESC) AS row_number
  FROM data
  ORDER BY k DESC;
