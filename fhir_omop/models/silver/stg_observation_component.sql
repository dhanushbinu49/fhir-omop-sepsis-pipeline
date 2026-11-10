-- Blood pressure from ED vital signs comes as 2 parts (systolic + diastolic)
-- in a $.component list. One row per part; each item is called comp.
select
  json_value(o.resource, '$.id')                                  as observation_id,
  pos                                                             as position,
  json_value(comp, '$.code.coding[0].code')                       as code,  -- 8480-6 systolic, 8462-4 diastolic
  json_value(comp, '$.code.coding[0].display')                    as code_display,
  cast(json_value(comp, '$.valueQuantity.value') as float64)      as value_number,
  json_value(comp, '$.valueQuantity.unit')                        as value_unit,
  o.source_file
from {{ source('bronze', 'fhir_resources') }} as o
cross join unnest(json_query_array(o.resource, '$.component')) as comp with offset as pos
where o.resource_type = 'Observation'
  -- bronze is clustered on these two columns, so BigQuery skips the other 8 files (cheaper)
  and o.source_file = 'MimicObservationVitalSignsED.ndjson.gz'
