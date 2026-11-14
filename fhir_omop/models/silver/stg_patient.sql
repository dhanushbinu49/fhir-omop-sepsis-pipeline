select  
  json_value(resource, '$.id')                                  as patient_id,
  cast(json_value(resource, '$.identifier[0].value') as int64)  as subject_id,
  json_value(resource, '$.gender')                              as gender,
  cast(json_value(resource, '$.birthDate') as date)             as birth_date,
  cast(json_value(resource, '$.deceasedDateTime') as date)      as death_date,

  -- the extension order varies, so find each one by its url
  (
    select json_value(ext, '$.extension[0].valueCoding.code')
    from unnest(json_query_array(resource, '$.extension')) as ext
    where ends_with(json_value(ext, '$.url'), 'us-core-race')
  )                                                             as race_code,
  (
    select json_value(ext, '$.extension[0].valueCoding.display')
    from unnest(json_query_array(resource, '$.extension')) as ext
    where ends_with(json_value(ext, '$.url'), 'us-core-race')
  )                                                             as race,
  (
    select json_value(ext, '$.extension[0].valueCoding.code')
    from unnest(json_query_array(resource, '$.extension')) as ext
    where ends_with(json_value(ext, '$.url'), 'us-core-ethnicity')
  )                                                             as ethnicity_code,
  (
    select json_value(ext, '$.extension[0].valueCoding.display')
    from unnest(json_query_array(resource, '$.extension')) as ext
    where ends_with(json_value(ext, '$.url'), 'us-core-ethnicity')
  )                                                             as ethnicity,

  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Patient'
