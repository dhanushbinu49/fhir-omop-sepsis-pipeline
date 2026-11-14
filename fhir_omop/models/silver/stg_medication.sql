-- the identifier order varies, so find each one by its system
select
  json_value(resource, '$.id')                                  as medication_id,
  source_file = 'MimicMedicationMix.ndjson.gz'                  as is_mix,
  (
    select json_value(i, '$.value')
    from unnest(json_query_array(resource, '$.identifier')) as i
    where ends_with(json_value(i, '$.system'), 'mimic-medication-ndc')
  )                                                             as ndc,
  (
    select json_value(i, '$.value')
    from unnest(json_query_array(resource, '$.identifier')) as i
    where ends_with(json_value(i, '$.system'), 'mimic-medication-formulary-drug-cd')
  )                                                             as formulary_code,
  (
    select json_value(i, '$.value')
    from unnest(json_query_array(resource, '$.identifier')) as i
    where ends_with(json_value(i, '$.system'), 'mimic-medication-name')
  )                                                             as drug_name,
  (
    select json_value(i, '$.value')
    from unnest(json_query_array(resource, '$.identifier')) as i
    where ends_with(json_value(i, '$.system'), 'medication-mix')
  )                                                             as mix_description,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Medication'
