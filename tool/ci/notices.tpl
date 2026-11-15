Third-party software in libtailcat
==================================

The libraries are built from https://github.com/tailscale/tailcat, whose
license is reproduced above, and link the Go modules listed below.

{{ range . }}
--------------------------------------------------------------------------------
{{ .Name }}{{ if .Version }} {{ .Version }}{{ end }}
License: {{ .LicenseName }} ({{ .LicenseURL }})

{{ .LicenseText }}
{{ end }}
