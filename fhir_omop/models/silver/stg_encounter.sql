select
  json_value(resource, '$.id')                                     as encounter_id,
  {{ reference_id('$.subject.reference') }}                        as patient_id,
  case source_file
    when 'MimicEncounter.ndjson.gz'    then 'hospital'
    when 'MimicEncounterED.ndjson.gz'  then 'ed'
    when 'MimicEncounterICU.ndjson.gz' then 'icu'
  end                                                              as encounter_type,
  cast(json_value(resource, '$.identifier[0].value') as int64)     as mimic_id,
  json_value(resource, '$.class.code')                             as class_code,
  {{ fhir_datetime('$.period.start') }}                            as start_datetime,
  {{ fhir_datetime('$.period.end') }}                              as end_datetime,
  {{ reference_id('$.partOf.reference') }}                         as parent_encounter_id,
  json_value(resource, '$.hospitalization.admitSource.coding[0].code')           as admit_source,
  json_value(resource, '$.hospitalization.dischargeDisposition.coding[0].code')  as discharge_disposition,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Encounter'
