select
  json_value(resource, '$.id')                                 as medication_statement_id,
  {{ reference_id('$.subject.reference') }}                    as patient_id,
  {{ reference_id('$.context.reference') }}                    as encounter_id,
  -- the coding order varies, so find the NDC by its system
  (
    select json_value(c, '$.code')
    from unnest(json_query_array(resource, '$.medicationCodeableConcept.coding')) as c
    where json_value(c, '$.system') = 'http://hl7.org/fhir/sid/ndc'
  )                                                            as ndc,
  json_value(resource, '$.medicationCodeableConcept.text')     as medication_text,
  {{ fhir_datetime('$.dateAsserted') }}                        as asserted_datetime,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'MedicationStatement'
