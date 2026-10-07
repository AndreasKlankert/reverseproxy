{{- define "nexus-jar-proxy.rootPath" -}}
{{- $path := regexReplaceAll "^https?://[^/]+" .Values.proxy.rootUrl "" -}}
{{- printf "%s/" (trimSuffix "/" $path) -}}
{{- end -}}

{{- define "nexus-jar-proxy.rootHost" -}}
{{- regexReplaceAll ":[0-9]+$" (regexFind "^[^/]+" (regexReplaceAll "^https?://" .Values.proxy.rootUrl "")) "" -}}
{{- end -}}
