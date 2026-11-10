-- Labs, vitals, chart events, microbiology results (9 source files, ~814k rows).
-- The value comes in different forms, so each form gets its own column:
-- value_number, value_string, value_code or value_datetime.
select
  json_value(resource, '$.id')                                             as observation_id,
  {{ reference_id('$.subject.reference') }}                                as patient_id,
  {{ reference_id('$.encounter.reference') }}                              as encounter_id,
  {{ reference_id('$.specimen.reference') }}                               as specimen_id,
  {{ reference_id('$.derivedFrom[0].reference') }}                         as parent_observation_id,  -- micro: organism -> its test, susceptibility -> its organism
  json_value(resource, '$.category[0].coding[0].code')                     as category,  -- a list here, unlike Procedure
  json_value(resource, '$.code.coding[0].system')                          as code_system,
  json_value(resource, '$.code.coding[0].code')                            as code,
  json_value(resource, '$.code.coding[0].display')                         as code_display,
  json_value(resource, '$.status')                                         as status,
  {{ fhir_datetime('$.effectiveDateTime') }}                               as effective_datetime,
  {{ fhir_datetime('$.issued') }}                                          as issued_datetime,
  cast(json_value(resource, '$.valueQuantity.value') as float64)           as value_number,
  json_value(resource, '$.valueQuantity.unit')                             as value_unit,
  json_value(resource, '$.valueQuantity.comparator')                       as value_comparator,  -- '<', '>=' ...
  json_value(resource, '$.valueString')                                    as value_string,
  json_value(resource, '$.valueCodeableConcept.coding[0].code')            as value_code,  -- e.g. S = susceptible, R = resistant
  {{ fhir_datetime('$.valueDateTime') }}                                   as value_datetime,
  cast(json_value(resource, '$.referenceRange[0].low.value') as float64)   as range_low,
  cast(json_value(resource, '$.referenceRange[0].high.value') as float64)  as range_high,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Observation'
