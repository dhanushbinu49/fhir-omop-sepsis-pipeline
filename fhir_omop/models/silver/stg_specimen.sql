select
  json_value(resource, '$.id')                                   as specimen_id,
  {{ reference_id('$.subject.reference') }}                      as patient_id,
  cast(json_value(resource, '$.identifier[0].value') as int64)   as mimic_id,
  json_value(resource, '$.type.coding[0].code')                  as specimen_type_code,
  json_value(resource, '$.type.coding[0].display')               as specimen_type,  -- 'BLOOD CULTURE' etc. (microbiology only)
  {{ fhir_datetime('$.collection.collectedDateTime') }}          as collected_datetime,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Specimen'
