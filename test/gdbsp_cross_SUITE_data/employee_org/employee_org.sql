-- Employees and the departments they belong to. manager_id points at
-- the employee's manager. A manager_id of 0 means the employee is
-- top-level (no manager).
CREATE TABLE employees (
    emp_id     INTEGER,
    name       TEXT,
    dept_id    INTEGER,
    manager_id INTEGER,
    salary     INTEGER
);

CREATE TABLE departments (
    dept_id   INTEGER,
    dept_name TEXT
);

-- Who reports to whom, transitively. A row (sub, mgr) means `sub` is a
-- direct or indirect report of `mgr`. Top-level employees (manager_id =
-- 0) never appear as a subordinate.
CREATE VIEW report_chain_set AS
WITH RECURSIVE chain(sub, mgr) AS (
    SELECT emp_id AS sub, manager_id AS mgr
    FROM employees
    WHERE manager_id <> 0
    UNION
    SELECT c.sub, e.manager_id
    FROM chain c
    JOIN employees e ON e.emp_id = c.mgr
    WHERE e.manager_id <> 0
)
SELECT sub, mgr FROM chain;

-- Department rollup: highest salary and headcount per department.
CREATE VIEW dept_stats_set AS
SELECT
    d.dept_id,
    d.dept_name,
    MAX(e.salary) AS max_salary,
    COUNT(*)       AS emp_count
FROM employees e
JOIN departments d ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name;

-- Employees earning the top salary in their department.
CREATE VIEW top_earners_set AS
SELECT
    e.emp_id,
    e.name,
    e.salary,
    e.dept_id
FROM employees e
JOIN (
    SELECT dept_id, MAX(salary) AS max_salary
    FROM employees
    GROUP BY dept_id
) m ON e.dept_id = m.dept_id AND e.salary = m.max_salary;
