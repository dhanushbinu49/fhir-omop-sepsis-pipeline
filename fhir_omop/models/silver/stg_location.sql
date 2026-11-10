select 
 json_value(resource, '$.id') as location_id,
 json_value(resource, '$.name') as location_name,
 json_value(resource, '$.physicalType.coding[0].display') as location_type,
 source_file
from {{ source('bronze', 'fhir_resources')  }}
where resource_type = 'Location'
