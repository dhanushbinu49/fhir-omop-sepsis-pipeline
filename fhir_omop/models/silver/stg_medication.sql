-- Drugs and drug mixes (e.g. an antibiotic in a saline bag).
-- Mixes are included because 2,843 medication requests point at a mix.
-- The identifier list order varies (identifier[0] is the NDC for most drugs,
-- but the formulary code or the name for others), so find each one by its system.
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
