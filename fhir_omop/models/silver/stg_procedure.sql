select
  json_value(resource, '$.id')                            as procedure_id,
  {{ reference_id('$.subject.reference') }}               as patient_id,
  {{ reference_id('$.encounter.reference') }}             as encounter_id,
  json_value(resource, '$.code.coding[0].system')         as code_system,
  json_value(resource, '$.code.coding[0].code')           as code,
  json_value(resource, '$.code.coding[0].display')        as code_display,
  json_value(resource, '$.status')                        as status,
  coalesce(
    {{ fhir_datetime('$.performedDateTime') }},
    {{ fhir_datetime('$.performedPeriod.start') }}
  )                                                       as start_datetime,
  {{ fhir_datetime('$.performedPeriod.end') }}            as end_datetime,
  json_value(resource, '$.category.coding[0].code')       as category,
  json_value(resource, '$.bodySite[0].coding[0].code')    as body_site,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Procedure'
