select
  json_value(m.resource, '$.id')                                as medication_id,
  pos                                                           as position,
  {{ reference_id('$.itemReference.reference', 'ing') }}        as ingredient_medication_id,
  m.source_file
from {{ source('bronze', 'fhir_resources') }} as m
cross join unnest(json_query_array(m.resource, '$.ingredient')) as ing with offset as pos
where m.resource_type = 'Medication'
