{{/*
Expand the name of the chart. Uses the ArgoCD Application name from values when set.
*/}}
{{- define "hyperfleet-api-chart.name" -}}
{{- default .Chart.Name .Values.hyperfleetApiChart.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hyperfleet-api-chart.fullname" -}}
{{- if .Values.hyperfleetApiChart.fullnameOverride }}
{{- .Values.hyperfleetApiChart.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "hyperfleet-api-chart.name" . }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hyperfleet-api-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hyperfleet-api-chart.labels" -}}
helm.sh/chart: {{ include "hyperfleet-api-chart.chart" . }}
{{ include "hyperfleet-api-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hyperfleet-api-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-api-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
