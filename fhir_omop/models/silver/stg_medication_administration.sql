-- When a drug was actually given: the antibiotics half of time-to-antibiotics.
select
  json_value(resource, '$.id')                                             as medication_administration_id,
  {{ reference_id('$.subject.reference') }}                                as patient_id,
  {{ reference_id('$.context.reference') }}                                as encounter_id,  -- called context here
  {{ reference_id('$.request.reference') }}                                as medication_request_id,  -- ICU rows have none
  json_value(resource, '$.medicationCodeableConcept.coding[0].system')     as medication_code_system,
  json_value(resource, '$.medicationCodeableConcept.coding[0].code')       as medication_code,
  json_value(resource, '$.medicationCodeableConcept.coding[0].display')    as medication_display,
  json_value(resource, '$.status')                                         as status,
  -- Either one time (effectiveDateTime) or a start and end (effectivePeriod)
  coalesce(
    {{ fhir_datetime('$.effectiveDateTime') }},
    {{ fhir_datetime('$.effectivePeriod.start') }}
  )                                                                        as start_datetime,
  {{ fhir_datetime('$.effectivePeriod.end') }}                             as end_datetime,
  cast(json_value(resource, '$.dosage.dose.value') as float64)             as dose_value,
  json_value(resource, '$.dosage.dose.unit')                               as dose_unit,
  cast(json_value(resource, '$.dosage.rateQuantity.value') as float64)     as rate_value,
  json_value(resource, '$.dosage.rateQuantity.unit')                       as rate_unit,
  json_value(resource, '$.dosage.method.coding[0].code')                   as method,
  json_value(resource, '$.category.coding[0].code')                        as category,  -- one object here, not a list
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'MedicationAdministration'
