/*
Read-only OpManagerDB extraction for historical DB-port KPI backfill.

Destination shape:
  exactly matches monitoring.db_port_blackbox_daily_kpi column order. The
  updated_at value is the UTC extraction timestamp. monitoring_excluded belongs
  to target inventory and is intentionally not part of this result.

Important source semantics:
  - OpManager daily rows contain seconds, not individual probes.
  - OpManager's published availability formula defines downtime as
    ELEMENTDOWN + PARENTDOWN + DEPENDENTUNAVAILABLE. Observed service time is
    UPTIME plus those three down states.
  - Maintenance, hold, and not-monitored time is unknown and is not fabricated
    as either UP or DOWN. Those states are retained by OpManager for reporting,
    but excluded from the availability denominator.
  - Observed seconds are converted to 5-minute-equivalent probe counts because
    the current blackbox writer stores 288 samples per complete day.
  - Any positive source downtime is represented by at least one failed 5-minute
    bucket. This prevents a short outage from being rounded to 100%
    availability. A partial bucket is therefore conservatively counted as one
    full failed bucket.
  - TCP-service response time is stored in STATSDATA* under the host's `stat`
    poll (OID 2.2.1.16). INSTANCE identifies the service (`MSSQL` or `Oracle`),
    while `Device` and `Packet_Loss` are different metrics and are excluded.
    PolledData.PERIOD is 300 or 900 seconds for the mapped source services;
    output counters and latency weights are normalized to 300 seconds.
  - STATSDATA_DAILY.VAL is OpManager's daily average response time in ms and
    MAXVALUE is its daily maximum. The archive does not retain sample counts,
    so latency_ms_count uses equivalent successful 5-minute probes and
    latency_ms_sum is derived from that count. This preserves the source daily
    average while keeping cross-day weighting compatible with the current KPI.
  - Daily response-time history begins on 2025-05-28 in this OpManagerDB.
    Older KPI rows retain zero latency sum/count and a zero maximum.
  - Daily archives do not retain exact first/last probe timestamps. For schema
    compatibility, first_probe_at is the start of period_start and
    last_probe_at is 23:59:59 on that date in the source UTC+07 timezone.
    These are reporting boundaries, not reconstructed individual probes.
  - A daily response archive cannot recover how many individual samples crossed
    the 3000 ms slow threshold, so slow_probes remains zero. Do not infer it
    from a daily maximum.
  - Exact historical event order cannot be reconstructed from daily summaries,
    so this query intentionally does not create synthetic raw probe rows.
    Exact state windows are available separately in DownTime*, ParentDown*,
    DependentUnavailable*, OnHold*, and OnMaintenance*.
  - TargetMap is copied from monitoring.db_port_blackbox_targets so names and
    dimensions join cleanly with the existing dashboard data.
  - OpManager reports MSSQL and Oracle on BMJKT-000095. The Oracle service uses
    target_name bmjkt-000095-oracle because PostgreSQL keys KPI rows by
    (period_start, target_name), while bmjkt-000095 is already the MSSQL target.

Current safe range:
  OpManager DB-service history starts at 2024-07-29.
  PostgreSQL collection started partway through 2026-07-06. OpManager owns that
  full day; PostgreSQL-only KPI history starts at 2026-07-07.

Archive table names below match MetaTable on 2026-08-20. Recheck MetaTable before
running this later because OpManager can rotate or remove archive tables.
*/

SET NOCOUNT ON;

DECLARE @FromInclusive date = '2024-07-29';
DECLARE @ToExclusive date = '2026-07-07';
DECLARE @BucketSeconds int = 300;
DECLARE @SourceUtcOffsetHours smallint = 7;
DECLARE @ResponseFromEpochMs bigint = DATEDIFF_BIG(
    SECOND,
    CONVERT(datetime2, '1970-01-01'),
    DATEADD(HOUR, -@SourceUtcOffsetHours, CONVERT(datetime2, DATEADD(DAY, 1, @FromInclusive)))
) * CONVERT(bigint, 1000);
DECLARE @ResponseToEpochMs bigint = DATEDIFF_BIG(
    SECOND,
    CONVERT(datetime2, '1970-01-01'),
    DATEADD(HOUR, -@SourceUtcOffsetHours, CONVERT(datetime2, DATEADD(DAY, 1, @ToExclusive)))
) * CONVERT(bigint, 1000);

WITH TargetMap AS
(
    SELECT
        target_name,
        host,
        port,
        db_type,
        environment,
        criticality,
        team,
        monitoring_excluded
    FROM (VALUES
        ('bmjkt-000019',  '172.31.100.19',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000041',  '172.31.99.41',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000042',  '172.31.99.42',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000043',  '172.31.99.43',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000043qa','172.31.99.93',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000044',  '172.31.99.44',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000045',  '10.126.2.2',      1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000046',  '172.31.99.46',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000048',  '10.121.2.48',     1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000051',  '172.31.100.51',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000053',  '172.31.100.53',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000057',  '172.31.100.57',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000058',  '172.31.100.58',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000071',  '172.31.100.71',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000084',  '10.126.2.84',     1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000091',  '172.31.99.91',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000095',  '172.31.100.95',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000095-oracle', '172.31.100.95', 1521, 'oracle', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000139',  '172.31.100.139', 1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000148',  '172.31.99.148',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000173',  '172.31.99.73',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000174',  '172.31.99.174',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000177',  '172.31.100.177', 1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000190',  '172.31.99.190',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000191',  '172.31.99.191',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000192',  '172.31.99.192',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000193',  '172.31.99.193',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000194',  '172.31.99.194',  1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000196',  '172.31.104.196', 1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmjkt-000197',  '172.31.104.197', 1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 1)),
        ('bmjkt-000658',  '172.31.100.158', 1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0)),
        ('bmsby-000045',  '172.28.44.45',   1433, 'sqlserver', 'prod', 'high', 'dba', CONVERT(bit, 0))
    ) AS mapped (
        target_name,
        host,
        port,
        db_type,
        environment,
        criticality,
        team,
        monitoring_excluded
    )
),
DiscoveredServices AS
(
    SELECT
        svc.MOID AS service_moid,
        svc.TYPE AS source_service_type,
        svc.PARENTKEY AS source_parent_key,
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
        discovered.source_service_type,
        discovered.source_parent_key,
        mapped.target_name,
        mapped.host,
        mapped.port,
        mapped.db_type,
        mapped.environment,
        mapped.criticality,
        mapped.team,
        mapped.monitoring_excluded
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
AllDaily AS
(
    SELECT
        0 AS source_priority,
        ea.ELEMENTID,
        ea.COLLECTIONTIME,
        ea.UPTIME,
        ea.ELEMENTDOWN,
        ea.ONMAINTENANCE,
        ea.ONHOLD,
        ea.PARENTDOWN,
        ea.DEPENDENTUNAVAILABLE,
        ea.NOTMONITORED
    FROM dbo.ElementAvailabilityDaily AS ea
    WHERE ea.COLLECTIONTIME >= @FromInclusive
      AND ea.COLLECTIONTIME < @ToExclusive

    UNION ALL

    SELECT
        1,
        ea.ELEMENTID,
        ea.COLLECTIONTIME,
        ea.UPTIME,
        ea.ELEMENTDOWN,
        ea.ONMAINTENANCE,
        ea.ONHOLD,
        ea.PARENTDOWN,
        ea.DEPENDENTUNAVAILABLE,
        ea.NOTMONITORED
    FROM dbo.ElementAvailabilityDaily2024_07_18_14 AS ea
    WHERE ea.COLLECTIONTIME >= @FromInclusive
      AND ea.COLLECTIONTIME < @ToExclusive
),
MappedDaily AS
(
    SELECT
        service.service_moid,
        service.source_service_type,
        service.source_parent_key,
        service.target_name,
        service.host,
        service.port,
        service.db_type,
        service.environment,
        service.criticality,
        service.team,
        service.monitoring_excluded,
        daily.COLLECTIONTIME,
        daily.UPTIME,
        daily.ELEMENTDOWN,
        daily.ONMAINTENANCE,
        daily.ONHOLD,
        daily.PARENTDOWN,
        daily.DEPENDENTUNAVAILABLE,
        daily.NOTMONITORED,
        ROW_NUMBER() OVER (
            PARTITION BY daily.ELEMENTID, daily.COLLECTIONTIME
            ORDER BY daily.source_priority
        ) AS source_row
    FROM AllDaily AS daily
    INNER JOIN DBServices AS service
        ON service.service_moid = daily.ELEMENTID
),
ObservedDaily AS
(
    SELECT
        mapped.*,
        mapped.ELEMENTDOWN
            + mapped.PARENTDOWN
            + mapped.DEPENDENTUNAVAILABLE AS total_down_seconds,
        mapped.UPTIME
            + mapped.ELEMENTDOWN
            + mapped.PARENTDOWN
            + mapped.DEPENDENTUNAVAILABLE AS observed_seconds,
        mapped.ONMAINTENANCE
            + mapped.ONHOLD
            + mapped.NOTMONITORED AS unknown_seconds
    FROM MappedDaily AS mapped
    WHERE mapped.source_row = 1
),
ResponsePolls AS
(
    SELECT
        service.service_moid,
        service.source_service_type,
        poll.ID AS response_poll_id
    FROM DBServices AS service
    INNER JOIN dbo.PolledData AS poll
        ON poll.PARENTOBJ = service.source_parent_key
       AND poll.NAME = 'stat'
       AND poll.OID = '2.2.1.16'
       AND poll.PROTOCOL = 'SPOLL'
),
AllResponseDaily AS
(
    SELECT
        0 AS source_priority,
        poll.service_moid,
        response.TTIME,
        response.VAL,
        response.MAXVALUE
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs

    UNION ALL

    SELECT
        1,
        poll.service_moid,
        response.TTIME,
        response.VAL,
        response.MAXVALUE
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY_2025_05_28_3 AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs

    UNION ALL

    SELECT
        1,
        poll.service_moid,
        response.TTIME,
        response.VAL,
        response.MAXVALUE
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY_2026_01_10_6 AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs

    UNION ALL

    SELECT
        1,
        poll.service_moid,
        response.TTIME,
        response.VAL,
        response.MAXVALUE
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY_2026_05_09_3 AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs
),
DecodedResponseDaily AS
(
    SELECT
        response.service_moid,
        DATEADD(
            DAY,
            -1,
            CONVERT(date, DATEADD(
                HOUR,
                @SourceUtcOffsetHours,
                DATEADD(
                    MILLISECOND,
                    CONVERT(int, response.TTIME % 1000),
                    DATEADD(
                        SECOND,
                        CONVERT(int, response.TTIME / 1000),
                        CONVERT(datetime2, '1970-01-01')
                    )
                )
            ))
        ) AS period_start,
        CONVERT(decimal(38, 10), response.VAL) AS avg_latency_ms,
        CONVERT(decimal(38, 10), response.MAXVALUE) AS max_latency_ms,
        response.source_priority,
        response.TTIME
    FROM AllResponseDaily AS response
    WHERE response.VAL >= 0
),
RankedResponseDaily AS
(
    SELECT
        response.*,
        ROW_NUMBER() OVER (
            PARTITION BY response.service_moid, response.period_start
            ORDER BY response.source_priority, response.TTIME DESC
        ) AS source_row
    FROM DecodedResponseDaily AS response
),
ResponseDaily AS
(
    SELECT
        service_moid,
        period_start,
        avg_latency_ms,
        max_latency_ms
    FROM RankedResponseDaily
    WHERE source_row = 1
),
EquivalentProbes AS
(
    SELECT
        observed.*,
        CONVERT(bigint, ROUND(observed.observed_seconds * 1.0 / @BucketSeconds, 0)) AS probes
    FROM ObservedDaily AS observed
    WHERE observed.observed_seconds > 0
),
RoundedCounts AS
(
    SELECT
        equivalent.*,
        CONVERT(bigint, ROUND(
            equivalent.probes * equivalent.total_down_seconds * 1.0
            / NULLIF(equivalent.observed_seconds, 0),
            0
        )) AS rounded_down_probes
    FROM EquivalentProbes AS equivalent
    WHERE equivalent.probes > 0
),
FinalCounts AS
(
    SELECT
        rounded.*,
        CASE
            WHEN rounded.total_down_seconds <= 0 THEN CONVERT(bigint, 0)
            WHEN rounded.UPTIME <= 0 THEN rounded.probes
            WHEN rounded.probes = 1 THEN CONVERT(bigint, 1)
            WHEN rounded.rounded_down_probes < 1 THEN CONVERT(bigint, 1)
            WHEN rounded.rounded_down_probes >= rounded.probes THEN rounded.probes - 1
            ELSE rounded.rounded_down_probes
        END AS down_probes
    FROM RoundedCounts AS rounded
)
SELECT
    CONVERT(date, final.COLLECTIONTIME) AS period_start,
    final.target_name,
    final.db_type,
    final.environment,
    final.host,
    final.port,
    final.host + ':' + CONVERT(varchar(5), final.port) AS instance,
    final.criticality,
    final.team,
    final.probes,
    final.probes - final.down_probes AS up_probes,
    final.down_probes,
    CONVERT(decimal(38, 6),
        CASE
            WHEN response.avg_latency_ms IS NULL THEN 0
            ELSE response.avg_latency_ms * (final.probes - final.down_probes)
        END
    ) AS latency_ms_sum,
    CONVERT(bigint,
        CASE
            WHEN response.avg_latency_ms IS NULL THEN 0
            ELSE final.probes - final.down_probes
        END
    ) AS latency_ms_count,
    TODATETIMEOFFSET(
        CONVERT(datetime2(0), CONVERT(date, final.COLLECTIONTIME)),
        @SourceUtcOffsetHours * 60
    ) AS first_probe_at,
    TODATETIMEOFFSET(
        DATEADD(
            SECOND,
            -1,
            DATEADD(
                DAY,
                1,
                CONVERT(datetime2(0), CONVERT(date, final.COLLECTIONTIME))
            )
        ),
        @SourceUtcOffsetHours * 60
    ) AS last_probe_at,
    TODATETIMEOFFSET(SYSUTCDATETIME(), '+00:00') AS updated_at,
    CONVERT(bigint, 0) AS slow_probes,
    CONVERT(decimal(38, 6), COALESCE(response.max_latency_ms, 0)) AS max_latency_ms
FROM FinalCounts AS final
LEFT JOIN ResponseDaily AS response
    ON response.service_moid = final.service_moid
   AND response.period_start = CONVERT(date, final.COLLECTIONTIME)
ORDER BY
    period_start,
    final.target_name;

/*
Pre-insert checks to run against the result:
  1. No duplicate (period_start, target_name).
  2. probes = up_probes + down_probes.
  3. period_start < 2026-07-07. Rows on 2026-07-06 intentionally replace the
     partial PostgreSQL day for mapped OpManager targets.
  4. updated_at is populated with the UTC extraction timestamp.
  5. Every source row with ELEMENTDOWN + PARENTDOWN + DEPENDENTUNAVAILABLE > 0
     has down_probes > 0.
  6. For rows with latency_ms_count > 0, latency_ms_sum / latency_ms_count
     matches STATSDATA_DAILY.VAL and max_latency_ms matches MAXVALUE. Rows
     without retained response data have latency sum/count/max all set to 0.
  7. first_probe_at is 00:00:00+07 and last_probe_at is 23:59:59+07 for
     period_start. They are synthetic daily boundaries, not source probe times.
  8. The CSV header exactly matches the physical PostgreSQL table:
     period_start through max_latency_ms, including updated_at.
  9. Export the result as UTF-8 CSV with a header for
     sql/opmanager_daily_kpi_backfill_load.sql.
*/
