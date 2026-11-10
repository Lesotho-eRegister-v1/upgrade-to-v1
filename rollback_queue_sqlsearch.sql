-- Removes the queue handlers added by fix_queue_sqlsearch.sql (returns to the broken state).
-- If a backup table exists from step 1, the plain emrapi.sqlSearch.* rows are untouched by the fix anyway.
DELETE FROM global_property WHERE property LIKE 'emrapi.sqlSearch.queue.%';
SELECT COUNT(*) AS queue_rows_left FROM global_property WHERE property LIKE 'emrapi.sqlSearch.queue.%';
