{#
  FHIR times look like '2180-07-23T12:35:00-04:00' (Boston clock time + offset).
  This returns a DATETIME with the same clock time: 2180-07-23 12:35:00.
  Usage: {{ fhir_datetime('$.period.start') }}  or  {{ fhir_datetime('$.period.start', 'loc') }}
#}
{% macro fhir_datetime(path, column='resource') %}
  datetime(cast(json_value({{ column }}, '{{ path }}') as timestamp), 'America/New_York')
{% endmacro %}
