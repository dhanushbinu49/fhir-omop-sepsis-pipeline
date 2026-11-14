select
  json_value(o.resource, '$.id')                                  as observation_id,
  pos                                                             as position,
  json_value(comp, '$.code.coding[0].code')                       as code,
  json_value(comp, '$.code.coding[0].display')                    as code_display,
  cast(json_value(comp, '$.valueQuantity.value') as float64)      as value_number,
  json_value(comp, '$.valueQuantity.unit')                        as value_unit,
  o.source_file
from {{ source('bronze', 'fhir_resources') }} as o
cross join unnest(json_query_array(o.resource, '$.component')) as comp with offset as pos
where o.resource_type = 'Observation'
  -- bronze is clustered on these columns, so BigQuery scans less
  and o.source_file = 'MimicObservationVitalSignsED.ndjson.gz'
