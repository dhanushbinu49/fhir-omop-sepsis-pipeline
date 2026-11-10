-- Drugs handed out by the pharmacy (hospital) or in the ED.
select
  json_value(resource, '$.id')                                               as medication_dispense_id,
  {{ reference_id('$.subject.reference') }}                                  as patient_id,
  {{ reference_id('$.context.reference') }}                                  as encounter_id,
  {{ reference_id('$.authorizingPrescription[0].reference') }}               as medication_request_id,
  json_value(resource, '$.medicationCodeableConcept.coding[0].system')       as medication_code_system,
  json_value(resource, '$.medicationCodeableConcept.coding[0].code')         as medication_code,
  json_value(resource, '$.medicationCodeableConcept.text')                   as medication_text,
  json_value(resource, '$.dosageInstruction[0].route.coding[0].code')        as route,
  json_value(resource, '$.dosageInstruction[0].timing.code.coding[0].code')  as frequency,
  {{ fhir_datetime('$.whenHandedOver') }}                                    as handed_over_datetime,
  json_value(resource, '$.status')                                           as status,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'MedicationDispense'
