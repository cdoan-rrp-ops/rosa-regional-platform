{{/*
Expand the name of the chart. Uses the ArgoCD Application name from values when set.
*/}}
{{- define "hyperfleet-sentinel1-chart.name" -}}
{{- default .Chart.Name .Values.hyperfleetSentinel1Chart.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hyperfleet-sentinel1-chart.fullname" -}}
{{- if .Values.hyperfleetSentinel1Chart.fullnameOverride }}
{{- .Values.hyperfleetSentinel1Chart.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "hyperfleet-sentinel1-chart.name" . }}
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
{{- define "hyperfleet-sentinel1-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hyperfleet-sentinel1-chart.labels" -}}
helm.sh/chart: {{ include "hyperfleet-sentinel1-chart.chart" . }}
{{ include "hyperfleet-sentinel1-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hyperfleet-sentinel1-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-sentinel1-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
