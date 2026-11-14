select
  json_value(resource, '$.id')                         as condition_id,
  {{ reference_id('$.subject.reference') }}            as patient_id,
  {{ reference_id('$.encounter.reference') }}          as encounter_id,
  json_value(resource, '$.code.coding[0].system')      as code_system,
  json_value(resource, '$.code.coding[0].code')        as code,
  json_value(resource, '$.code.coding[0].display')     as code_display,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Condition'
