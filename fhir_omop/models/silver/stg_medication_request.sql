-- Prescriptions / orders. Each request names its drug in one of two ways:
-- a link to a Medication (medication_id) or a code written inline (medication_code).
select
  json_value(resource, '$.id')                                               as medication_request_id,
  {{ reference_id('$.subject.reference') }}                                  as patient_id,
  {{ reference_id('$.encounter.reference') }}                                as encounter_id,
  {{ reference_id('$.medicationReference.reference') }}                      as medication_id,
  json_value(resource, '$.medicationCodeableConcept.coding[0].system')       as medication_code_system,
  json_value(resource, '$.medicationCodeableConcept.coding[0].code')         as medication_code,
  json_value(resource, '$.status')                                           as status,
  {{ fhir_datetime('$.authoredOn') }}                                        as authored_datetime,
  {{ fhir_datetime('$.dispenseRequest.validityPeriod.start') }}              as start_datetime,
  {{ fhir_datetime('$.dispenseRequest.validityPeriod.end') }}                as end_datetime,
  json_value(resource, '$.dosageInstruction[0].route.coding[0].code')        as route,
  cast(json_value(resource, '$.dosageInstruction[0].doseAndRate[0].doseQuantity.value') as float64)  as dose_value,
  json_value(resource, '$.dosageInstruction[0].doseAndRate[0].doseQuantity.unit')                    as dose_unit,
  json_value(resource, '$.dosageInstruction[0].timing.code.coding[0].code')  as frequency,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'MedicationRequest'
