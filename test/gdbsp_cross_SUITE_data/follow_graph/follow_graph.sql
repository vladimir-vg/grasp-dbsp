-- Users and the directed follow relationships between them. A row in
-- follows means follower_id follows followee_id.
CREATE TABLE users (
    user_id INTEGER,
    name    TEXT
);

CREATE TABLE follows (
    follower_id INTEGER,
    followee_id INTEGER
);

-- Who can reach whom through the follow graph, transitively. A row
-- (src, dst) means src follows dst directly or indirectly.
CREATE VIEW reach_set AS
WITH RECURSIVE reach(src, dst) AS (
    SELECT follower_id AS src, followee_id AS dst
    FROM follows
    UNION
    SELECT r.src, f.followee_id
    FROM reach r
    JOIN follows f ON f.follower_id = r.dst
)
SELECT src, dst FROM reach;

-- How many distinct users each user can reach, directly or indirectly.
CREATE VIEW influence_set AS
SELECT src, COUNT(*) AS reach_count
FROM reach_set
GROUP BY src;

-- Pairs of users who follow each other. Each pair appears once, ordered
-- by user id.
CREATE VIEW mutual_set AS
SELECT f1.follower_id, f1.followee_id
FROM follows f1
JOIN follows f2
  ON f2.follower_id = f1.followee_id
 AND f2.followee_id = f1.follower_id
WHERE f1.follower_id < f1.followee_id;
