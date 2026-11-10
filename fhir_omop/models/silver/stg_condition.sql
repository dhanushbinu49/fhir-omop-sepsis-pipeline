-- Diagnoses (ICD-9 or ICD-10). MIMIC diagnoses have no date of their own;
-- gold will use the encounter's dates.
select
  json_value(resource, '$.id')                         as condition_id,
  {{ reference_id('$.subject.reference') }}            as patient_id,
  {{ reference_id('$.encounter.reference') }}          as encounter_id,
  json_value(resource, '$.code.coding[0].system')      as code_system,
  json_value(resource, '$.code.coding[0].code')        as code,  -- e.g. 'V462', '4019': no dots, keep as text
  json_value(resource, '$.code.coding[0].display')     as code_display,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Condition'
