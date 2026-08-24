/*
Read-only drill-down for validating one OpManager TCP-service target.

Change only the three parameters below. The query returns:
  1. source inventory and native response polling interval;
  2. daily availability states, exact source KPI, 5-minute normalization, and
     daily response latency;
  3. exact closed state windows that overlap the selected range;
  4. any currently open state; and
  5. retained performance data-collection failures.

No PostgreSQL table is touched and no source table is modified.

Archive table names below match MetaTable on 2026-08-20. Recheck MetaTable before
running this later because OpManager can rotate or remove archive tables.
*/

SET NOCOUNT ON;

DECLARE @TargetName varchar(255) = 'bmjkt-000197';
DECLARE @FromInclusive date = '2026-07-01';
DECLARE @ToExclusive date = '2026-07-07';
DECLARE @BucketSeconds int = 300;
DECLARE @SourceUtcOffsetHours smallint = 7;

DECLARE @ResponseFromEpochMs bigint = DATEDIFF_BIG(
    SECOND,
    CONVERT(datetime2, '1970-01-01'),
    DATEADD(
        HOUR,
        -@SourceUtcOffsetHours,
        CONVERT(datetime2, DATEADD(DAY, 1, @FromInclusive))
    )
) * CONVERT(bigint, 1000);

DECLARE @ResponseToEpochMs bigint = DATEDIFF_BIG(
    SECOND,
    CONVERT(datetime2, '1970-01-01'),
    DATEADD(
        HOUR,
        -@SourceUtcOffsetHours,
        CONVERT(datetime2, DATEADD(DAY, 1, @ToExclusive))
    )
) * CONVERT(bigint, 1000);

DECLARE @Services TABLE
(
    service_moid bigint PRIMARY KEY,
    source_service_type varchar(50) NOT NULL,
    source_parent_key varchar(255) NOT NULL,
    source_target_name varchar(255) NOT NULL,
    source_display_name varchar(255) NULL,
    source_address varchar(255) NULL,
    source_port int NULL
);

INSERT INTO @Services
SELECT
    svc.MOID,
    svc.TYPE,
    svc.PARENTKEY,
    discovered.source_target_name,
    COALESCE(NULLIF(parent.DISPLAYNAME, ''), parent.NAME),
    inet.TARGETADDRESS,
    inet.PORTNO
FROM dbo.ManagedObject AS svc
INNER JOIN dbo.ManagedObject AS parent
    ON parent.NAME = svc.PARENTKEY
CROSS APPLY
(
    SELECT
        CASE
            WHEN parent.NAME NOT LIKE '[0-9]%'
                THEN LOWER(LEFT(parent.NAME, CHARINDEX('.', parent.NAME + '.') - 1))
            WHEN CHARINDEX('(', parent.DISPLAYNAME) > 0
             AND CHARINDEX(
                    ')',
                    parent.DISPLAYNAME,
                    CHARINDEX('(', parent.DISPLAYNAME) + 1
                 ) > CHARINDEX('(', parent.DISPLAYNAME)
                THEN LOWER(LTRIM(RTRIM(SUBSTRING(
                    parent.DISPLAYNAME,
                    CHARINDEX('(', parent.DISPLAYNAME) + 1,
                    CHARINDEX(
                        ')',
                        parent.DISPLAYNAME,
                        CHARINDEX('(', parent.DISPLAYNAME) + 1
                    ) - CHARINDEX('(', parent.DISPLAYNAME) - 1
                ))))
            ELSE LOWER(LTRIM(RTRIM(parent.DISPLAYNAME)))
        END + CASE WHEN svc.TYPE = 'Oracle' THEN '-oracle' ELSE '' END
            AS source_target_name
) AS discovered
LEFT JOIN dbo.InetService AS inet
    ON inet.NAME = svc.NAME
WHERE svc.TYPE IN ('MSSQL', 'Oracle')
  AND discovered.source_target_name = LOWER(@TargetName);

IF NOT EXISTS (SELECT 1 FROM @Services)
BEGIN
    THROW 50001, 'Target was not found as an MSSQL or Oracle TCP service', 1;
END;

-- Result 1: identity, target address, and actual response polling cadence.
SELECT
    service.source_target_name,
    service.source_display_name,
    service.source_service_type,
    service.service_moid,
    service.source_address,
    service.source_port,
    poll.ID AS response_poll_id,
    poll.PERIOD AS response_poll_interval_seconds,
    poll.ACTIVE AS response_poll_active,
    poll.FAILURETHRESHOLD AS response_failure_threshold,
    definition.TIMEOUT AS tcp_timeout_seconds
FROM @Services AS service
LEFT JOIN dbo.PolledData AS poll
    ON poll.PARENTOBJ = service.source_parent_key
   AND poll.NAME = 'stat'
   AND poll.OID = '2.2.1.16'
   AND poll.PROTOCOL = 'SPOLL'
LEFT JOIN dbo.TCPServicesDefinition AS definition
    ON definition.SERVICENAME = service.source_service_type
ORDER BY service.source_service_type;

-- Result 2: source availability and its conservative 5-minute equivalent.
WITH AllDaily AS
(
    SELECT
        0 AS source_priority,
        availability.*
    FROM dbo.ElementAvailabilityDaily AS availability
    WHERE availability.COLLECTIONTIME >= @FromInclusive
      AND availability.COLLECTIONTIME < @ToExclusive

    UNION ALL

    SELECT
        1,
        availability.*
    FROM dbo.ElementAvailabilityDaily2024_07_18_14 AS availability
    WHERE availability.COLLECTIONTIME >= @FromInclusive
      AND availability.COLLECTIONTIME < @ToExclusive
),
RankedDaily AS
(
    SELECT
        daily.*,
        ROW_NUMBER() OVER (
            PARTITION BY daily.ELEMENTID, daily.COLLECTIONTIME
            ORDER BY daily.source_priority
        ) AS source_row
    FROM AllDaily AS daily
    INNER JOIN @Services AS service
        ON service.service_moid = daily.ELEMENTID
),
ObservedDaily AS
(
    SELECT
        daily.*,
        daily.ELEMENTDOWN
            + daily.PARENTDOWN
            + daily.DEPENDENTUNAVAILABLE AS total_down_seconds,
        daily.UPTIME
            + daily.ELEMENTDOWN
            + daily.PARENTDOWN
            + daily.DEPENDENTUNAVAILABLE AS observed_seconds,
        daily.ONHOLD
            + daily.ONMAINTENANCE
            + daily.NOTMONITORED AS unknown_seconds
    FROM RankedDaily AS daily
    WHERE daily.source_row = 1
),
ResponsePolls AS
(
    SELECT
        service.service_moid,
        service.source_service_type,
        poll.ID AS response_poll_id
    FROM @Services AS service
    INNER JOIN dbo.PolledData AS poll
        ON poll.PARENTOBJ = service.source_parent_key
       AND poll.NAME = 'stat'
       AND poll.OID = '2.2.1.16'
       AND poll.PROTOCOL = 'SPOLL'
),
AllResponseDaily AS
(
    SELECT 0 AS source_priority, poll.service_moid, response.*
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs

    UNION ALL

    SELECT 1, poll.service_moid, response.*
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY_2025_05_28_3 AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs

    UNION ALL

    SELECT 1, poll.service_moid, response.*
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY_2026_01_10_6 AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs

    UNION ALL

    SELECT 1, poll.service_moid, response.*
    FROM ResponsePolls AS poll
    INNER JOIN dbo.STATSDATA_DAILY_2026_05_09_3 AS response
        ON response.POLLID = poll.response_poll_id
       AND response.INSTANCE = poll.source_service_type
       AND response.TTIME >= @ResponseFromEpochMs
       AND response.TTIME < @ResponseToEpochMs
),
DecodedResponse AS
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
        response.VAL AS avg_latency_ms,
        response.MINVALUE AS min_latency_ms,
        response.MAXVALUE AS max_latency_ms,
        response.source_priority,
        response.TTIME
    FROM AllResponseDaily AS response
    WHERE response.VAL >= 0
),
RankedResponse AS
(
    SELECT
        response.*,
        ROW_NUMBER() OVER (
            PARTITION BY response.service_moid, response.period_start
            ORDER BY response.source_priority, response.TTIME DESC
        ) AS source_row
    FROM DecodedResponse AS response
),
Equivalent AS
(
    SELECT
        observed.*,
        CONVERT(bigint, ROUND(observed.observed_seconds * 1.0 / @BucketSeconds, 0))
            AS probes_5m
    FROM ObservedDaily AS observed
),
Rounded AS
(
    SELECT
        equivalent.*,
        CONVERT(bigint, ROUND(
            equivalent.probes_5m * equivalent.total_down_seconds * 1.0
            / NULLIF(equivalent.observed_seconds, 0),
            0
        )) AS rounded_down_probes
    FROM Equivalent AS equivalent
    WHERE equivalent.probes_5m > 0
),
Final AS
(
    SELECT
        rounded.*,
        CASE
            WHEN rounded.total_down_seconds <= 0 THEN CONVERT(bigint, 0)
            WHEN rounded.UPTIME <= 0 THEN rounded.probes_5m
            WHEN rounded.probes_5m = 1 THEN CONVERT(bigint, 1)
            WHEN rounded.rounded_down_probes < 1 THEN CONVERT(bigint, 1)
            WHEN rounded.rounded_down_probes >= rounded.probes_5m
                THEN rounded.probes_5m - 1
            ELSE rounded.rounded_down_probes
        END AS down_probes_5m
    FROM Rounded AS rounded
)
SELECT
    CONVERT(date, final.COLLECTIONTIME) AS period_start,
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
    final.UPTIME AS up_seconds,
    final.ELEMENTDOWN AS element_down_seconds,
    final.PARENTDOWN AS parent_down_seconds,
    final.DEPENDENTUNAVAILABLE AS dependent_unavailable_seconds,
    final.ONHOLD AS on_hold_seconds,
    final.ONMAINTENANCE AS maintenance_seconds,
    final.NOTMONITORED AS not_monitored_seconds,
    final.observed_seconds,
    final.unknown_seconds,
    CONVERT(decimal(18, 8),
        final.UPTIME * 100.0 / NULLIF(final.observed_seconds, 0)
    ) AS source_availability_pct,
    final.probes_5m,
    final.probes_5m - final.down_probes_5m AS up_probes_5m,
    final.down_probes_5m,
    CONVERT(decimal(18, 8),
        (final.probes_5m - final.down_probes_5m) * 100.0
        / NULLIF(final.probes_5m, 0)
    ) AS normalized_availability_pct,
    response.avg_latency_ms,
    response.min_latency_ms,
    CONVERT(decimal(38, 6), COALESCE(response.max_latency_ms, 0))
        AS max_latency_ms
FROM Final AS final
LEFT JOIN RankedResponse AS response
    ON response.service_moid = final.ELEMENTID
   AND response.period_start = CONVERT(date, final.COLLECTIONTIME)
   AND response.source_row = 1
ORDER BY period_start;

-- Result 3: exact closed state windows. Only the first three states are DOWN.
WITH AllStateEvents AS
(
    SELECT 0 source_priority, 'ELEMENTDOWN' state_type, event.* FROM dbo.DownTime AS event
    UNION ALL SELECT 1, 'ELEMENTDOWN', event.* FROM dbo.DownTime2024_07_18_14 AS event
    UNION ALL SELECT 0, 'PARENTDOWN', event.* FROM dbo.ParentDown AS event
    UNION ALL SELECT 1, 'PARENTDOWN', event.* FROM dbo.ParentDown2024_07_18_14 AS event
    UNION ALL SELECT 0, 'DEPENDENTUNAVAILABLE', event.* FROM dbo.DependentUnavailable AS event
    UNION ALL SELECT 1, 'DEPENDENTUNAVAILABLE', event.* FROM dbo.DependentUnavailable2024_07_18_14 AS event
    UNION ALL SELECT 0, 'ONHOLD', event.* FROM dbo.OnHold AS event
    UNION ALL SELECT 1, 'ONHOLD', event.* FROM dbo.OnHold2024_07_18_14 AS event
    UNION ALL SELECT 0, 'ONMAINTENANCE', event.* FROM dbo.OnMaintenance AS event
    UNION ALL SELECT 1, 'ONMAINTENANCE', event.* FROM dbo.OnMaintenance2024_07_18_14 AS event
),
RankedStateEvents AS
(
    SELECT
        event.*,
        ROW_NUMBER() OVER (
            PARTITION BY event.state_type, event.ELEMENTID, event.STARTTIME
            ORDER BY event.source_priority
        ) AS source_row
    FROM AllStateEvents AS event
    INNER JOIN @Services AS service
        ON service.service_moid = event.ELEMENTID
    WHERE event.STARTTIME < CONVERT(datetime2, @ToExclusive)
      AND event.ENDTIME > CONVERT(datetime2, @FromInclusive)
)
SELECT
    state_type,
    CASE
        WHEN state_type IN ('ELEMENTDOWN', 'PARENTDOWN', 'DEPENDENTUNAVAILABLE')
            THEN 'DOWN'
        ELSE 'UNKNOWN_EXCLUDED'
    END AS availability_class,
    STARTTIME AS start_at,
    ENDTIME AS end_at,
    DATEDIFF_BIG(MILLISECOND, STARTTIME, ENDTIME) / 1000.0 AS duration_seconds,
    NULLIF(LTRIM(RTRIM(REASON)), '') AS reason
FROM RankedStateEvents
WHERE source_row = 1
ORDER BY STARTTIME, state_type;

-- Result 4: currently open states. STARTTIME is epoch milliseconds in these tables.
WITH OpenStates AS
(
    SELECT 'ELEMENTDOWN' state_type, event.* FROM dbo.DownTimeStart AS event
    UNION ALL SELECT 'PARENTDOWN', event.* FROM dbo.ParentDownStart AS event
    UNION ALL SELECT 'DEPENDENTUNAVAILABLE', event.* FROM dbo.DependentUnavailableStart AS event
    UNION ALL SELECT 'ONHOLD', event.* FROM dbo.OnHoldStart AS event
    UNION ALL SELECT 'ONMAINTENANCE', event.* FROM dbo.MaintenanceStart AS event
)
SELECT
    state.state_type,
    DATEADD(
        HOUR,
        @SourceUtcOffsetHours,
        DATEADD(
            MILLISECOND,
            CONVERT(int, state.STARTTIME % 1000),
            DATEADD(
                SECOND,
                CONVERT(int, state.STARTTIME / 1000),
                CONVERT(datetime2, '1970-01-01')
            )
        )
    ) AS start_at
FROM OpenStates AS state
INNER JOIN @Services AS service
    ON service.service_moid = state.ELEMENTID
ORDER BY start_at;

-- Result 5: retained response polling failures. Retention is short by design;
-- the archive list is the MetaTable snapshot noted at the top of this file.
WITH ResponsePolls AS
(
    SELECT poll.ID AS response_poll_id
    FROM @Services AS service
    INNER JOIN dbo.PolledData AS poll
        ON poll.PARENTOBJ = service.source_parent_key
       AND poll.NAME = 'stat'
       AND poll.OID = '2.2.1.16'
       AND poll.PROTOCOL = 'SPOLL'
),
AllCollectionFailures AS
(
    SELECT * FROM dbo.DataCollectionLog
    UNION ALL SELECT * FROM dbo.DataCollectionLog_2026_08_11_21
    UNION ALL SELECT * FROM dbo.DataCollectionLog_2026_08_14_15
    UNION ALL SELECT * FROM dbo.DataCollectionLog_2026_08_17_9
    UNION ALL SELECT * FROM dbo.DataCollectionLog_2026_08_19_23
)
SELECT
    failure.POLLTIME AS failed_at,
    failure.ERRORCODE AS error_code,
    failure.FAILUREREASON AS failure_reason
FROM AllCollectionFailures AS failure
INNER JOIN ResponsePolls AS poll
    ON poll.response_poll_id = failure.POLLID
WHERE failure.POLLTIME >= CONVERT(datetime, @FromInclusive)
  AND failure.POLLTIME < CONVERT(datetime, @ToExclusive)
ORDER BY failure.POLLTIME;
