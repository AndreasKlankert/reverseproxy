{{- define "nexus-jar-proxy.rootPath" -}}
{{- $path := regexReplaceAll "^https?://[^/]+" .Values.proxy.rootUrl "" -}}
{{- printf "%s/" (trimSuffix "/" $path) -}}
{{- end -}}

{{- define "nexus-jar-proxy.caConfigMap" -}}
{{- if and .Values.nexus.caConfigMap .Values.nexus.caBundle -}}
{{- fail "Set either nexus.caConfigMap (existing ConfigMap name) or nexus.caBundle (PEM content), not both" -}}
{{- end -}}
{{- if .Values.nexus.caBundle -}}
{{- printf "%s-ca" .Release.Name -}}
{{- else -}}
{{- .Values.nexus.caConfigMap -}}
{{- end -}}
{{- end -}}

{{- define "nexus-jar-proxy.rootHost" -}}
{{- regexReplaceAll ":[0-9]+$" (regexFind "^[^/]+" (regexReplaceAll "^https?://" .Values.proxy.rootUrl "")) "" -}}
{{- end -}}
