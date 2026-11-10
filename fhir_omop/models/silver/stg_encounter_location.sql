-- One row per ward a patient stayed in during a hospital stay.
-- $.location is a list, so unnest turns each item (called loc) into its own row.
select
  json_value(e.resource, '$.id')                        as encounter_id,
  pos                                                   as position,
  {{ reference_id('$.location.reference', 'loc') }}     as location_id,
  {{ fhir_datetime('$.period.start', 'loc') }}          as start_datetime,
  {{ fhir_datetime('$.period.end', 'loc') }}            as end_datetime,
  e.source_file
from {{ source('bronze', 'fhir_resources') }} as e
cross join unnest(json_query_array(e.resource, '$.location')) as loc with offset as pos
where e.resource_type = 'Encounter'
