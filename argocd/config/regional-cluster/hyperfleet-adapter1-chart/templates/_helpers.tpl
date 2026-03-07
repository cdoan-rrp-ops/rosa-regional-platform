{{/*
Expand the name of the chart. Uses the ArgoCD Application name from values when set.
*/}}
{{- define "hyperfleet-adapter1-chart.name" -}}
{{- default .Chart.Name .Values.hyperfleetAdapter1Chart.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hyperfleet-adapter1-chart.fullname" -}}
{{- if .Values.hyperfleetAdapter1Chart.fullnameOverride }}
{{- .Values.hyperfleetAdapter1Chart.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "hyperfleet-adapter1-chart.name" . }}
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
{{- define "hyperfleet-adapter1-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hyperfleet-adapter1-chart.labels" -}}
helm.sh/chart: {{ include "hyperfleet-adapter1-chart.chart" . }}
{{ include "hyperfleet-adapter1-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hyperfleet-adapter1-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-adapter1-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
