-- Weighted average change: each comparison to the previous pgver is weighted by its share (%) of the total sum of (loop_dur + lag_loop_dur)
select query_mode,
  (sum(dur_ch * weight_pct) / sum(weight_pct))::numeric(5,1) as weighted_avg_dur_ch
from (
select *, 100::numeric * (loop_dur - lag_loop_dur) / lag_loop_dur as dur_ch,
  100 * (loop_dur + lag_loop_dur) / sum(loop_dur + lag_loop_dur) over () as weight_pct
from (
    select *, lag(loop_dur) over w as lag_loop_dur
    from (
    select distinct
      hostname, test_start_time, query_mode, scale, pgver, loop_dur
    from pgss_results order by 1, 2, 3, 4, 5
    ) x
    window w as (partition by hostname, test_start_time, query_mode, scale order by pgver)
) y
where lag_loop_dur notnull
) z
group by rollup (query_mode)
order by 1 nulls last
;
