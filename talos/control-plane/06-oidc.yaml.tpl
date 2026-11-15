# Lets the kube-apiserver accept Authelia's ID tokens (client `headlamp`, see
# apps/sso), so Headlamp passes the logged-in user's token on and RBAC applies
# per user. Talos 1.14 owns the --authentication-config file, so this is the
# KubeAuthenticationConfig document (the --oidc-* flags are rejected). The
# anonymous block repeats Talos's default (health endpoints only), because
# `configuration` is the literal file. Identities show up as `oidc:<user>`
# and groups as `oidc:<group>` (RBAC: infrastructure/base/headlamp). The issuer
# URL must equal Authelia's issuer byte for byte; its certificate is a public
# one, so the system CAs in the apiserver pod suffice.
apiVersion: v1alpha1
kind: KubeAuthenticationConfig
configuration:
  anonymous:
    enabled: true
    conditions:
      - path: /livez
      - path: /readyz
      - path: /healthz
  jwt:
    - issuer:
        url: https://sso.{{ .Data.gatewayDomain }}
        audiences:
          - headlamp
        audienceMatchPolicy: MatchAny
      claimMappings:
        username:
          claim: preferred_username
          prefix: "oidc:"
        groups:
          claim: groups
          prefix: "oidc:"
