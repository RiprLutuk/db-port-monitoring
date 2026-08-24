/*
Read-only extraction of exact OpManager DB-service downtime events.

This query complements opmanager_daily_kpi_backfill_extract.sql:
  - daily KPI supplies historical availability counters;
  - this query supplies the real start/end timestamp of each outage.

OpManager can move one continuous outage between ELEMENTDOWN, PARENTDOWN, and
DEPENDENTUNAVAILABLE. The query therefore merges overlapping or touching state
windows for the same service before exporting them. ONHOLD, ONMAINTENANCE, and
NOTMONITORED are intentionally excluded because they are unknown time, not
confirmed downtime.

The output exactly matches monitoring.db_port_blackbox_downtime_events column
order and is accepted by opmanager_downtime_events_load.sql. It never creates
synthetic raw probe rows and it does not assume that downtime happened between
00:00 and 03:00. Event timestamps use an explicit Asia/Jakarta offset; audit
timestamps use UTC.

Archive table names match the MetaTable snapshot audited on 2026-08-20. Recheck
MetaTable before a later run because OpManager may rotate or remove archives.
*/

SET NOCOUNT ON;

DECLARE @FromInclusive date = '2024-07-29';
DECLARE @ToExclusive date = '2026-07-07';
DECLARE @BucketSeconds int = 300;
DECLARE @SourceUtcOffset varchar(6) = '+07:00';
DECLARE @FromAt datetime2(3) = CONVERT(datetime2(3), @FromInclusive);
DECLARE @ToAt datetime2(3) = CONVERT(datetime2(3), @ToExclusive);

WITH TargetMap AS
(
    SELECT
        target_name,
        host,
        port,
        db_type,
        environment,
        criticality,
        team
    FROM (VALUES
        ('bmjkt-000019',  '172.31.100.19',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000025',  '10.121.2.29',     1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000041',  '172.31.99.41',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000042',  '172.31.99.42',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000043',  '172.31.99.43',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000043qa','172.31.99.93',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000044',  '172.31.99.44',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000045',  '10.126.2.2',     1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000046',  '172.31.99.46',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000048',  '10.121.2.48',    1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000051',  '172.31.100.51',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000053',  '172.31.100.53',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000057',  '172.31.100.57',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000058',  '172.31.100.58',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000071',  '172.31.100.71',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000084',  '10.126.2.84',    1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000091',  '172.31.99.91',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000095',  '172.31.100.95',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000095-oracle', '172.31.100.95', 1521, 'oracle', 'prod', 'high', 'dba'),
        ('bmjkt-000139',  '172.31.100.139', 1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000148',  '172.31.99.148',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000173',  '172.31.99.73',   1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000174',  '172.31.99.174',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000177',  '172.31.100.177', 1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000190',  '172.31.99.190',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000191',  '172.31.99.191',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000192',  '172.31.99.192',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000193',  '172.31.99.193',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000194',  '172.31.99.194',  1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000196',  '172.31.104.196', 1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000197',  '172.31.104.197', 1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000264',  '10.126.2.147',    1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000273',  '172.31.104.173', 1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmjkt-000658',  '172.31.100.158', 1433, 'sqlserver', 'prod', 'high', 'dba'),
        ('bmsby-000045',  '172.28.44.45',   1433, 'sqlserver', 'prod', 'high', 'dba')
    ) AS mapped (
        target_name,
        host,
        port,
        db_type,
        environment,
        criticality,
        team
    )
),
DiscoveredServices AS
(
    SELECT
        svc.MOID AS service_moid,
        CASE
            WHEN parent.NAME NOT LIKE '[0-9]%'
                THEN LOWER(LEFT(parent.NAME, CHARINDEX('.', parent.NAME + '.') - 1))
            WHEN CHARINDEX('(', parent.DISPLAYNAME) > 0
             AND CHARINDEX(')', parent.DISPLAYNAME, CHARINDEX('(', parent.DISPLAYNAME) + 1)
                    > CHARINDEX('(', parent.DISPLAYNAME)
                THEN LOWER(LTRIM(RTRIM(SUBSTRING(
                    parent.DISPLAYNAME,
                    CHARINDEX('(', parent.DISPLAYNAME) + 1,
                    CHARINDEX(')', parent.DISPLAYNAME, CHARINDEX('(', parent.DISPLAYNAME) + 1)
                        - CHARINDEX('(', parent.DISPLAYNAME) - 1
                ))))
            ELSE LOWER(LTRIM(RTRIM(parent.DISPLAYNAME)))
        END AS target_name,
        CASE svc.TYPE
            WHEN 'MSSQL' THEN 'sqlserver'
            WHEN 'Oracle' THEN 'oracle'
        END AS db_type,
        TRY_CONVERT(int, RIGHT(svc.NAME, CHARINDEX('_', REVERSE(svc.NAME)) - 1)) AS port
    FROM dbo.ManagedObject AS svc
    INNER JOIN dbo.ManagedObject AS parent
        ON parent.NAME = svc.PARENTKEY
    WHERE svc.TYPE IN ('MSSQL', 'Oracle')
),
DBServices AS
(
    SELECT
        discovered.service_moid,
        mapped.target_name,
        mapped.host,
        mapped.port,
        mapped.db_type,
        mapped.environment,
        mapped.criticality,
        mapped.team
    FROM DiscoveredServices AS discovered
    INNER JOIN TargetMap AS mapped
        ON (
            mapped.target_name = discovered.target_name
            OR (
                discovered.db_type = 'oracle'
                AND mapped.target_name = discovered.target_name + '-oracle'
            )
        )
       AND mapped.db_type = discovered.db_type
       AND mapped.port = discovered.port
),
AllDownStateEvents AS
(
    SELECT
        0 AS source_priority,
        CONVERT(varchar(32), 'ELEMENTDOWN') AS state_type,
        event.ELEMENTID,
        CONVERT(datetime2(3), event.STARTTIME) AS start_at,
        CONVERT(datetime2(3), event.ENDTIME) AS end_at
    FROM dbo.DownTime AS event

    UNION ALL

    SELECT 1, 'ELEMENTDOWN', event.ELEMENTID,
        CONVERT(datetime2(3), event.STARTTIME), CONVERT(datetime2(3), event.ENDTIME)
    FROM dbo.DownTime2024_07_18_14 AS event

    UNION ALL

    SELECT 0, 'PARENTDOWN', event.ELEMENTID,
        CONVERT(datetime2(3), event.STARTTIME), CONVERT(datetime2(3), event.ENDTIME)
    FROM dbo.ParentDown AS event

    UNION ALL

    SELECT 1, 'PARENTDOWN', event.ELEMENTID,
        CONVERT(datetime2(3), event.STARTTIME), CONVERT(datetime2(3), event.ENDTIME)
    FROM dbo.ParentDown2024_07_18_14 AS event

    UNION ALL

    SELECT 0, 'DEPENDENTUNAVAILABLE', event.ELEMENTID,
        CONVERT(datetime2(3), event.STARTTIME), CONVERT(datetime2(3), event.ENDTIME)
    FROM dbo.DependentUnavailable AS event

    UNION ALL

    SELECT 1, 'DEPENDENTUNAVAILABLE', event.ELEMENTID,
        CONVERT(datetime2(3), event.STARTTIME), CONVERT(datetime2(3), event.ENDTIME)
    FROM dbo.DependentUnavailable2024_07_18_14 AS event
),
RankedDownStateEvents AS
(
    SELECT
        event.*,
        ROW_NUMBER() OVER (
            PARTITION BY event.state_type, event.ELEMENTID, event.start_at
            ORDER BY event.source_priority, event.end_at DESC
        ) AS source_row
    FROM AllDownStateEvents AS event
    INNER JOIN DBServices AS service
        ON service.service_moid = event.ELEMENTID
    WHERE event.start_at IS NOT NULL
      AND event.end_at IS NOT NULL
      AND event.end_at > event.start_at
      AND event.start_at < @ToAt
      AND event.end_at > @FromAt
),
ClippedDownStateEvents AS
(
    SELECT
        event.ELEMENTID,
        event.state_type,
        CASE WHEN event.start_at < @FromAt THEN @FromAt ELSE event.start_at END AS down_start,
        CASE WHEN event.end_at > @ToAt THEN @ToAt ELSE event.end_at END AS down_end,
        CONVERT(bit, CASE WHEN event.start_at < @FromAt THEN 1 ELSE 0 END) AS started_before_range,
        CONVERT(bit, CASE WHEN event.end_at > @ToAt THEN 1 ELSE 0 END) AS ended_after_range
    FROM RankedDownStateEvents AS event
    WHERE event.source_row = 1
),
RunningWindows AS
(
    SELECT
        event.*,
        MAX(event.down_end) OVER (
            PARTITION BY event.ELEMENTID
            ORDER BY event.down_start, event.down_end, event.state_type
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_end
    FROM ClippedDownStateEvents AS event
    WHERE event.down_end > event.down_start
),
EventGroups AS
(
    SELECT
        event.*,
        SUM(CASE
            WHEN event.prior_max_end IS NULL OR event.down_start > event.prior_max_end THEN 1
            ELSE 0
        END) OVER (
            PARTITION BY event.ELEMENTID
            ORDER BY event.down_start, event.down_end, event.state_type
            ROWS UNBOUNDED PRECEDING
        ) AS event_group
    FROM RunningWindows AS event
),
MergedEvents AS
(
    SELECT
        event.ELEMENTID,
        event.event_group,
        MIN(event.down_start) AS down_start,
        MAX(event.down_end) AS down_end,
        MAX(CONVERT(int, event.started_before_range)) AS started_before_range,
        MAX(CONVERT(int, event.ended_after_range)) AS ended_after_range,
        COUNT_BIG(*) AS source_event_segments,
        MAX(CASE WHEN event.state_type = 'ELEMENTDOWN' THEN 1 ELSE 0 END) AS has_element_down,
        MAX(CASE WHEN event.state_type = 'PARENTDOWN' THEN 1 ELSE 0 END) AS has_parent_down,
        MAX(CASE WHEN event.state_type = 'DEPENDENTUNAVAILABLE' THEN 1 ELSE 0 END) AS has_dependency_down
    FROM EventGroups AS event
    GROUP BY event.ELEMENTID, event.event_group
),
ShapedEvents AS
(
    SELECT
        service.target_name,
        event.down_start,
        event.down_end,
        service.db_type,
        service.environment,
        service.host,
        service.port,
        service.host + ':' + CONVERT(varchar(5), service.port) AS instance,
        service.criticality,
        service.team,
        CASE
            WHEN CEILING(
                DATEDIFF_BIG(MILLISECOND, event.down_start, event.down_end)
                / (@BucketSeconds * 1000.0)
            ) < 1 THEN CONVERT(bigint, 1)
            ELSE CONVERT(bigint, CEILING(
                DATEDIFF_BIG(MILLISECOND, event.down_start, event.down_end)
                / (@BucketSeconds * 1000.0)
            ))
        END AS down_samples,
        STUFF(
            CASE WHEN event.has_element_down = 1 THEN '+ELEMENTDOWN' ELSE '' END
            + CASE WHEN event.has_parent_down = 1 THEN '+PARENTDOWN' ELSE '' END
            + CASE WHEN event.has_dependency_down = 1 THEN '+DEPENDENTUNAVAILABLE' ELSE '' END,
            1,
            1,
            ''
        ) AS state_types,
        event.source_event_segments,
        CONVERT(bit, event.started_before_range) AS started_before_range,
        CONVERT(bit, event.ended_after_range) AS ended_after_range
    FROM MergedEvents AS event
    INNER JOIN DBServices AS service
        ON service.service_moid = event.ELEMENTID
)
SELECT
    event.target_name,
    TODATETIMEOFFSET(event.down_start, @SourceUtcOffset) AS down_start,
    TODATETIMEOFFSET(event.down_end, @SourceUtcOffset) AS down_end,
    TODATETIMEOFFSET(DATEADD(MILLISECOND, -1, event.down_end), @SourceUtcOffset) AS last_down_at,
    event.db_type,
    event.environment,
    event.host,
    event.port,
    event.instance,
    event.criticality,
    event.team,
    event.down_samples,
    'OpManager exact down states: ' + event.state_types
        + CASE
            WHEN event.started_before_range = 1
                THEN '; start clipped at backfill boundary'
            ELSE ''
          END AS first_error_text,
    'OpManager exact down states: ' + event.state_types
        + CASE
            WHEN event.ended_after_range = 1
                THEN '; end clipped at backfill boundary'
            ELSE ''
          END AS last_error_text,
    CONVERT(decimal(38, 6), 0) AS max_latency_ms,
    CASE
        WHEN event.started_before_range = 1 OR event.ended_after_range = 1
            THEN 'opmanager-exact-clipped'
        ELSE 'opmanager-exact'
    END AS source,
    CONVERT(bit, event.started_before_range) AS started_before_retention,
    TODATETIMEOFFSET(SYSUTCDATETIME(), '+00:00') AS created_at,
    TODATETIMEOFFSET(SYSUTCDATETIME(), '+00:00') AS updated_at
FROM ShapedEvents AS event
ORDER BY event.target_name, event.down_start;

/*
Export this result as UTF-8 CSV with a header. Before loading, verify:
  1. Every down_end is later than down_start.
  2. Events for one target do not overlap after state-window merging.
  3. The sum of exact event seconds reconciles with the corresponding daily
     ELEMENTDOWN + PARENTDOWN + DEPENDENTUNAVAILABLE seconds.
  4. A boundary-clipped event is clearly marked and is not called a recovery at
     the extraction boundary in reporting.
  5. max_latency_ms is 0 because OpManager state events do not retain a latency
     measurement for the outage window; it is a placeholder, not measured 0 ms.
  6. The CSV header exactly matches the physical PostgreSQL downtime-event table,
     from target_name through updated_at.
*/
