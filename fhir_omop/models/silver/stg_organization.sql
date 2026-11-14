select
  json_value(resource, '$.id')                   as organization_id,
  json_value(resource, '$.name')                 as organization_name,
  json_value(resource, '$.identifier[0].value')  as npi,
  source_file
from {{ source('bronze', 'fhir_resources') }}
where resource_type = 'Organization'
