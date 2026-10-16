-- [params]
-- date :since = 2026-10-26

-- Week-two return (PRD 3, part 3 of the Cardwell community plugin).
--
-- A new member's day 1 is their first visit (user_visits). Week two is days 8
-- to 14. They "returned on their own" if any visit day in week two has a
-- direct row, or no row at all (opening the home screen app from the
-- background reaches no page load, so it leaves none). A day with only tagged
-- rows was a day Cardwell brought them.
--
-- :since must be on or after the day cardwell_visit_source_enabled was turned
-- on. Before that no day has a row, so every visit would look like their own.
-- Staff are left out. One row per month of first visit. The last columns count
-- members by what brought them back in week two (a member can count in more
-- than one).

WITH new_members AS (
  SELECT u.id AS user_id, MIN(uv.visited_at) AS first_day
  FROM users u
  JOIN user_visits uv ON uv.user_id = u.id
  WHERE u.id > 0 AND NOT u.admin AND NOT u.moderator AND NOT u.staged
  GROUP BY u.id
  HAVING MIN(uv.visited_at) >= :since
),
week_two_days AS (
  SELECT
    nm.user_id,
    uv.visited_at,
    ARRAY_REMOVE(ARRAY_AGG(vs.source), NULL) AS sources
  FROM new_members nm
  JOIN user_visits uv
    ON uv.user_id = nm.user_id
    AND uv.visited_at BETWEEN nm.first_day + 7 AND nm.first_day + 13
  LEFT JOIN cardwell_visit_sources vs
    ON vs.user_id = uv.user_id AND vs.visited_at = uv.visited_at
  GROUP BY nm.user_id, uv.visited_at
),
per_member AS (
  SELECT
    nm.user_id,
    nm.first_day,
    nm.first_day + 13 < CURRENT_DATE AS week_two_over,
    COALESCE(BOOL_OR(CARDINALITY(d.sources) = 0 OR 'direct' = ANY (d.sources)), FALSE) AS on_own,
    COALESCE(BOOL_OR('digest' = ANY (d.sources)), FALSE) AS by_digest,
    COALESCE(BOOL_OR('notification' = ANY (d.sources)), FALSE) AS by_notification,
    COALESCE(BOOL_OR('push' = ANY (d.sources)), FALSE) AS by_push,
    COALESCE(BOOL_OR('invite' = ANY (d.sources) OR 'reminder' = ANY (d.sources)), FALSE) AS by_invite_or_reminder,
    COUNT(d.visited_at) > 0 AS returned
  FROM new_members nm
  LEFT JOIN week_two_days d ON d.user_id = nm.user_id
  GROUP BY nm.user_id, nm.first_day
)
SELECT
  DATE_TRUNC('month', first_day)::date AS first_visit_month,
  COUNT(*) AS new_members,
  COUNT(*) FILTER (WHERE week_two_over) AS week_two_over,
  COUNT(*) FILTER (WHERE week_two_over AND on_own) AS returned_on_own,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE week_two_over AND on_own)
      / NULLIF(COUNT(*) FILTER (WHERE week_two_over), 0),
    1
  ) AS week_two_return_pct,
  COUNT(*) FILTER (WHERE week_two_over AND returned AND NOT on_own) AS returned_only_when_brought,
  COUNT(*) FILTER (WHERE week_two_over AND by_digest) AS brought_by_digest,
  COUNT(*) FILTER (WHERE week_two_over AND by_notification) AS brought_by_notification,
  COUNT(*) FILTER (WHERE week_two_over AND by_push) AS brought_by_push,
  COUNT(*) FILTER (WHERE week_two_over AND by_invite_or_reminder) AS brought_by_invite_or_reminder
FROM per_member
GROUP BY 1
ORDER BY 1
