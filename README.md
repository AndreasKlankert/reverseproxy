# Nexus JAR Proxy fuer Apache Doris

Doris ruft eine JAR-URL ohne Authentifizierung auf. Dieser kleine NGINX-Proxy
setzt `Authorization: Basic <base64(username:password)>` und streamt die
Nexus-Antwort an Doris zurueck. Kein eigenes Image, keine Registry-Pipeline.

```text
Doris FE/BE -> HTTP(S) Proxy -> HTTPS Nexus mit Basic Auth -> JAR zurueck
```

Die [Doris-4.x-Dokumentation](https://doris.apache.org/docs/4.x/lakehouse/catalogs/jdbc-catalog-overview/)
beschreibt fuer `driver_url` HTTP-Dienste ohne Authentifizierung.
Der Proxy verwendet die [NGINX-Proxy-Direktiven](https://nginx.org/en/docs/http/ngx_http_proxy_module.html).

## 1. Zugangsdaten bereitstellen

Im Nexus einen Benutzer mit Leserechten fuer das gewuenschte Repository verwenden.
Das Secret muss im selben Namespace wie der Proxy liegen. Du kannst es manuell
bereitstellen oder mit der unten beschriebenen Vault-Anbindung erzeugen lassen.

```sh
kubectl create namespace doris
cp examples/nexus-secret.example.yaml secret.yaml
# In secret.yaml username und password ersetzen.
kubectl apply -f secret.yaml
```

`secret.yaml` ist in `.gitignore`. Alternativ das Secret ueber euren bestehenden
External-Secrets- oder Sealed-Secrets-Prozess bereitstellen. Echte Zugangsdaten
gehoeren weder in Git noch in Helm values.

### Mit vorhandenem Vault und External Secrets

Der Chart kann optional ein `ExternalSecret` anlegen. Voraussetzung sind ein
installierter External Secrets Operator und ein bereits mit Vault verbundener
`ClusterSecretStore` oder `SecretStore`. Vault allein reicht dafuer nicht aus.
Die Vault-Verbindung und deren Authentifizierung bleiben im vorhandenen Store.
Siehe [Vault-Anbindung des Operators](https://external-secrets.io/latest/provider/hashicorp-vault/).

In `examples/vault-values.yaml` anpassen:

- `externalSecret.secretStoreRef.name`: Name deines Vault-Stores.
- `externalSecret.secretStoreRef.kind`: `ClusterSecretStore` oder `SecretStore`.
  Ein `SecretStore` muss im Namespace des Proxys liegen.
- `externalSecret.username.key` und `password.key`: Vault-Pfade relativ zum
  KV-Mount des Stores, beispielsweise `applications/nexus` beim Mount `secret`.
- `externalSecret.username.property` und `password.property`: Feldnamen in Vault.
  Fuer verschachtelte Felder sind auch Pfade wie `credentials.password` moeglich.
- `externalSecret.apiVersion`: standardmaessig `external-secrets.io/v1`;
  fuer aeltere CRDs bei Bedarf `external-secrets.io/v1beta1` setzen.

```sh
helm upgrade --install nexus-jar-proxy ./charts/nexus-jar-proxy \
  --namespace doris --create-namespace \
  --set nexus.url=https://nexus.firma.de \
  -f examples/vault-values.yaml
```

Bei Argo CD die Werte aus dieser Datei unter `source.helm.valuesObject`
uebernehmen. Der Operator erzeugt das Secret mit dem Namen aus
`nexus.existingSecret` und den Schluesseln aus `nexus.usernameKey` und
`nexus.passwordKey`. Dieses Ziel-Secret wird vom `ExternalSecret` verwaltet;
es nicht gleichzeitig manuell oder mit einem anderen Controller verwalten.
Bis zur ersten erfolgreichen Synchronisierung wartet der Proxy auf das Secret.

```sh
kubectl -n doris get externalsecret nexus-jar-proxy-nexus-credentials
kubectl -n doris wait --for=condition=Ready \
  externalsecret/nexus-jar-proxy-nexus-credentials --timeout=120s
```

Der Operator aktualisiert das Secret standardmaessig jede Stunde.
Nach einer Rotation die Proxy-Pods neu starten, da sie die Zugangsdaten beim
Start lesen (siehe unten). Ohne `externalSecret.enabled: true` verwendet der
Chart weiterhin nur das vorhandene Kubernetes-Secret.

## 2. Mit Argo CD deployen

Dieses Projekt in dein GitHub-Repository hochladen. In
`argocd/application.yaml` anpassen:

- `repoURL`: dein GitHub-Repository; bei privaten Repositories muss Argo CD Zugriff haben.
- `targetRevision`: dein Branch, standardmaessig `main`.
- `proxy.rootUrl`: Aufruf-Root-URL des Proxys, z.B. `http://nexus-jar-proxy.doris.svc.cluster.local`.
- `nexus.url`: Ziel-Root-URL, z.B. `https://nexus.firma.de` oder `https://nexus.firma.de/repository/drivers/`.
- `destination.namespace`: Namespace fuer den Proxy und das Secret.

```sh
kubectl apply -f argocd/application.yaml
```

Die Application erstellt Deployment, ConfigMap und ClusterIP-Service und
synchronisiert weitere Git-Aenderungen automatisch.

Direkt mit Helm geht es ebenfalls:

```sh
helm upgrade --install nexus-jar-proxy ./charts/nexus-jar-proxy \
  --namespace doris --create-namespace \
  --set nexus.url=https://nexus.firma.de
```

## 3. URL in Doris setzen

Du konfigurierst zwei Root-URLs. Alles hinter der Proxy-Root wird an die
Ziel-Root angehaengt, inklusive Query-Parametern. Der Proxy setzt dabei den
Basic-Auth-Header aus dem Nexus-Secret. Beliebige Pfade sind erlaubt; eine
Liste einzelner JARs oder Verzeichnisse ist nicht erforderlich.

```yaml
proxy:
  rootUrl: http://nexus-jar-proxy.doris.svc.cluster.local
nexus:
  url: https://zielnexus.de
```

```text
http://nexus-jar-proxy.doris.svc.cluster.local/driver/jar1
-> https://zielnexus.de/driver/jar1

http://nexus-jar-proxy.doris.svc.cluster.local/irgendwas/jar2?download=1
-> https://zielnexus.de/irgendwas/jar2?download=1
```

Beide Root-URLs koennen auch einen Basispfad enthalten:

```yaml
proxy:
  rootUrl: http://nexus-jar-proxy.doris.svc.cluster.local/jars/
nexus:
  url: https://zielnexus.de/repository/drivers/
```

```text
http://nexus-jar-proxy.doris.svc.cluster.local/jars/any/path.jar?download=1
-> https://zielnexus.de/repository/drivers/any/path.jar?download=1
```

`examples/root-values.yaml` zeigt diese Konfiguration. Root-URLs duerfen keine
Zugangsdaten, Query oder Fragmente enthalten; ein abschliessender Slash ist optional.
Bei einer Proxy-Root mit Basispfad muss der Aufruf unter diesem Pfad liegen.
Die Umsetzung verwendet die [URI-Ersetzung von NGINX proxy_pass](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass).

Der Host in `proxy.rootUrl` muss auf den Service oder Ingress aufloesen.
Der Service heisst weiterhin wie der Helm-Release und liegt im Deployment-Namespace;
die Root-URL erzeugt keinen DNS-Eintrag. Bei aktiviertem Ingress werden Host
und Pfad aus `proxy.rootUrl` verwendet, sofern `ingress.host` keinen Override setzt.
HTTPS zum Proxy benoetigt den Ingress mit TLS; der ClusterIP-Service spricht HTTP.

Ein vollstaendiges `CREATE CATALOG` steht in `examples/doris.sql`. Die dortigen
`user`/`password` sind die Datenbank-Zugangsdaten, nicht die Nexus-Zugangsdaten.
Alle Doris FE- und BE-Nodes muessen die Proxy-URL erreichen koennen. Falls
`jdbc_driver_secure_path` eingeschraenkt ist, den Proxy-URL-Prefix dort erlauben.

## Von ausserhalb des Clusters

Optional einen Ingress aktivieren. `examples/external-values.yaml` zeigt die
Werte fuer Proxy-Root-URL, Ingress-Class und ein vorhandenes TLS-Secret. DNS muss auf den
Ingress zeigen; ein Ingress-Controller muss bereits installiert sein.

Mit Helm diese Datei zusaetzlich mit `-f examples/external-values.yaml` angeben.
Bei Argo CD dieselben `proxy`- und `ingress`-Werte unter `source.helm.valuesObject` eintragen.
Dann kann Doris beispielsweise diese URL verwenden:

```text
https://jars.example.com/repository/maven-public/com/mysql/mysql-connector-j/8.3.0/mysql-connector-j-8.3.0.jar
```

Der Proxy selbst ist absichtlich ohne Login, damit Doris herunterladen kann.
Jeder erreichbare Client kann damit Inhalte unter der konfigurierten Ziel-Root mit den
Leserechten des Secret-Benutzers abrufen. Den Zugang per Firewall, NetworkPolicy
oder Ingress-IP-Allowlist auf eure Doris-Nodes begrenzen. Keine Nexus-Admin-Credentials
verwenden. Der Ingress fuegt keine weitere Anmeldung hinzu.

## Verhalten und Betrieb

- Beliebige Pfade unter der Proxy-Root werden weitergeleitet; GET und HEAD sind erlaubt, andere Methoden liefern 403. Bei einer Root mit Basispfad liefern Pfade ausserhalb dieser Root 404.
- Kein Upload, kein Cache, kein festes JAR-Groessenlimit. Binaerdaten werden gestreamt.
- Range- und bedingte Download-Header werden an Nexus weitergegeben.
- Nexus-Statuscodes wie 401, 403 und 404 werden an Doris zurueckgegeben.
- Der Zielhost ist fest konfiguriert; eingehende Auth-Header werden ersetzt.
- HTTPS zu Nexus prueft Zertifikate und verwendet SNI. HTTP ist fuer interne Nexus-Endpunkte konfigurierbar.
- Fuer eine private CA: ConfigMap mit `ca.crt` als PEM-Bundle erstellen und `nexus.caConfigMap` setzen.
- `/healthz` ist fuer die lokale Health-Pruefung reserviert und wird nicht an Nexus weitergeleitet. Es prueft den Proxy-Prozess, nicht Nexus oder die Gueltigkeit des Passworts.
- Nach Secret- oder CA-Aenderungen die Pods neu starten:

```sh
kubectl -n doris rollout restart deployment/nexus-jar-proxy
```

## Pruefen

```sh
helm lint charts/nexus-jar-proxy
helm template nexus-jar-proxy charts/nexus-jar-proxy
kubectl -n doris port-forward service/nexus-jar-proxy 8080:80
# In einem zweiten Terminal, mit einem existierenden Nexus-Artefakt:
curl --fail -o driver.jar http://localhost:8080/repository/maven-public/com/mysql/mysql-connector-j/8.3.0/mysql-connector-j-8.3.0.jar
```

`bash tests/smoke.sh` prueft mit Docker einen simulierten Nexus, Basic Auth,
JAR-Binaerdaten, GET/HEAD, Range, Fehlercodes und gesperrte Schreibzugriffe.
GitHub Actions fuehrt Helm-Checks und den Smoke-Test mit und ohne Basispfade aus.
