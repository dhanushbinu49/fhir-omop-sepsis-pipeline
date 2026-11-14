{% macro fhir_datetime(path, column='resource') %}
  datetime(cast(json_value({{ column }}, '{{ path }}') as timestamp), 'America/New_York')
{% endmacro %}
