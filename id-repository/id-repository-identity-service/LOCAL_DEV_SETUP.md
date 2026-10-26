# Identity Service — Local Development Setup

How to build, run and debug the ID Repository **Identity Service** (`id-repository-identity-service`) on a developer machine, without a MOSIP platform deployment.

---

## 1. Overview

In a real environment the Identity Service needs about a dozen other MOSIP components before it can even start: PostgreSQL, the config server, Keycloak, keymanager, an S3 object store, the biometric SDK service, masterdata, the ID generator, the VID service, PMS, the credential request generator, audit manager and WebSub.

This setup replaces all of them:

- **Docker Compose** starts five lightweight containers: PostgreSQL, the MOSIP config server, WireMock (which stubs every MOSIP REST dependency), the MOSIP biosdk server with the mock SDK, and an S3-compatible store.
- **The service itself** runs on your machine through Maven or your IDE, under the `local-dev` Maven profile and the `localdev` Spring profile, so you can debug it normally.
- **Configuration** comes from an unmodified clone of [`mosip-config`](https://github.com/mosip/mosip-config). On top of it, the config server serves a committed overrides file that points every dependency at the local containers.

```
                      ┌──────────────────────────── docker compose ────────────────────────────┐
 Identity Service ───▶│ config-server :51000  ── mosip-config clone + local-dev-setup/config    │
 (mvn / IDE) :8090    │ database      :5455   ── PostgreSQL, mosip_idrepo (repo db_scripts)     │
                      │ mock-service  :8082   ── WireMock: Keycloak, keymanager, masterdata,     │
                      │                          idgenerator, VID svc, PMS, credential, audit,   │
                      │                          WebSub                                         │
                      │ biosdk-service:8083   ── MOSIP biosdk server + mock SDK                  │
                      │ object-store  :9090   ── S3 (Adobe S3Mock), bucket "idrepo"              │
                      └─────────────────────────────────────────────────────────────────────────┘
```

The design follows MOSIP's reference setup for ID Authentication ([`id-authentication/authentication/local-dev-setup`](https://github.com/mosip/id-authentication/tree/develop/authentication/local-dev-setup)), adapted to the Identity Service's dependencies. See [section 14](#14-deviations-from-the-id-authentication-reference).

> ⚠️ **Development only.** The keymanager stub does **not** encrypt anything. Identity data, UINs, handles and documents are stored **base64-encoded, not encrypted**. Every password, salt, secret and token in this setup is a throwaway value. Never point this configuration at real data.

---

## 2. Prerequisites

| Tool | Version | Used for |
|------|---------|----------|
| Git | any | cloning `id-repository` and `mosip-config` |
| Java (JDK) | **21** | building and running the service |
| Maven | **3.9.x** | build; runs the service (`spring-boot:run`) |
| Docker + Docker Compose v2 | recent | backing services (`docker compose`) |
| curl | any (built into Windows 10+) | `prepare-biosdk-mock-lib.*`, API calls |
| zip | any (macOS/Linux only) | `prepare-biosdk-mock-lib.sh` |
| PowerShell 5+ | Windows only | `prepare-biosdk-mock-lib.bat` (uses `Compress-Archive`) |

Internet access is needed on first run: Maven Central for dependencies and the mock SDK, and Docker Hub for images.

**Ports that must be free:**

| Port | Used by |
|------|---------|
| 5455 | `database` (PostgreSQL) |
| 51000 | `config-server` |
| 8082 | `mock-service` (WireMock) |
| 8083 | `biosdk-service` |
| 9090 | `object-store` (S3Mock) |
| **8090** | **Identity Service** |

---

## 3. Repository / Directory Structure

Everything for this setup lives in the identity-service module:

```
id-repository/                                   (git root)
├── db_scripts/mosip_idrepo/                     existing DDL — mounted into the database container
└── id-repository/                               Maven parent POM (build from here)
    ├── id-repository-core/                      shared library (must be installed first)
    └── id-repository-identity-service/
        ├── LOCAL_DEV_SETUP.md                   ◀ this document
        ├── pom.xml                              MODIFIED — adds the "local-dev" Maven profile
        ├── src/main/resources/
        │   ├── bootstrap.properties             unchanged (port 8090, servlet path)
        │   └── bootstrap-localdev.properties    ADDED — used only with Spring profile "localdev"
        └── local-dev-setup/                     ADDED
            ├── README.md                        pointer to this document + quick start
            ├── .gitattributes                   keeps *.sh LF / *.bat CRLF
            ├── .gitignore                       ignores mock-sdk.zip and docker-compose/.env
            ├── config/
            │   └── id-repository-localdev.properties   config overlay (Spring profile "localdev")
            ├── docker-compose/
            │   ├── docker-compose.yml           the five backing services
            │   ├── .env.example                 template for .env (MOSIP_CONFIG_DIR)
            │   ├── init-db/
            │   │   ├── 01-init-idrepo.sh        creates mosip_idrepo from db_scripts/mosip_idrepo
            │   │   └── sql/seed-salts.sql       dev salts for uin_hash_salt / uin_encrypt_salt
            │   └── wiremock/
            │       ├── mappings/dev-login.json          /dev-login: sets the dev-token cookie, opens Swagger UI
            │       ├── mappings/iam.json                Keycloak token + userinfo, authmanager
            │       ├── mappings/keymanager.json         encrypt/decrypt (echo)
            │       ├── mappings/masterdata.json         ID schema v0.1
            │       ├── mappings/platform-services.json  audit, idgenerator, VID (2 stubs), PMS, credential, WebSub, SDK download
            │       └── __files/                         EMPTY-FILE (+ generated mock-sdk.zip, git-ignored)
            ├── prepare-biosdk-mock-lib.sh       builds mock-sdk.zip (macOS/Linux)
            ├── prepare-biosdk-mock-lib.bat      builds mock-sdk.zip (Windows)
            └── samples/
                ├── dev-token.txt                long-lived dev JWT with all identity-service roles
                ├── add-identity.json            create request (UIN 3649229809 + one document)
                ├── update-identity.json         update request (changes phone)
                └── set-2/                       second test data set: 8 numbered requests + README (run order, expected results)
```

### Files added or modified

| File | Change | Purpose |
|------|--------|---------|
| `pom.xml` | **modified** (+30 lines, nothing removed) | New `local-dev` profile: adds `io.mosip.kernel:kernel-auth-adapter:${project.version}` (1.3.1) and `io.mosip.biosdk:biosdk-client:1.3.0` (runtime). It also sets `spring-boot.run.profiles=localdev` and the `--add-opens` JVM arguments. The default build and the packaged jar are unchanged. |
| `src/main/resources/bootstrap-localdev.properties` | added | Config server URL, label, profiles and LoadBalancer switch for local runs (see [section 6](#6-configuration)) |
| `local-dev-setup/**` | added | Everything listed in the tree above |
| `CLAUDE.md` (module) | added | Code guide for the module (API, architecture, encryption, credential flow, drafts, known hazards); points to this document |
| `CLAUDE.md` (repo root) | added | Repository map: where the parent POM is, build/test commands, how the services fit together |

No Java source, `bootstrap.properties`, `Dockerfile` or `db_scripts` file was changed.

---

## 4. Dependencies / External Services

What each dependency is, why the service needs it, and what replaces it locally:

| Real dependency | Why the service needs it | Local replacement | Port |
|---|---|---|---|
| PostgreSQL `mosip_idrepo` | all `idrepo.*` tables; startup fails without it | `database` (postgres:16-bookworm), built from `db_scripts/mosip_idrepo` | 5455 |
| Salt generator job | fills `uin_hash_salt` / `uin_encrypt_salt` (ids 0–999); every UIN hash needs them | `init-db/sql/seed-salts.sql` (deterministic dev salts) | — |
| MOSIP config server + `mosip-config` | all runtime configuration; `identity-mapping.json` and `mosip-cbeff.xsd` are fetched from it over HTTP at startup | `config-server` (mosipid/config-server:latest, native mode) | 51000 |
| Keycloak (via `kernel-auth-adapter`) | (a) the service's own token for outgoing calls; (b) validating incoming tokens | WireMock `iam.json` (token + userinfo) + `samples/dev-token.txt` | 8082 |
| Kernel keymanager (`/v1/keymanager/encrypt`, `/decrypt`) | every DB save/load and object-store read/write is encrypted remotely | WireMock `keymanager.json` — **echoes data back** | 8082 |
| S3 object store (khazana `s3Adapter`) | biometric and demographic document files. The filesystem adapter is excluded in code, so S3 is mandatory | `object-store` (adobe/s3mock:5.2.3) | 9090 |
| Biometric SDK | startup fails with `SDK_REGISTRY_EMPTY` unless an SDK registers; used for template extraction | `biosdk-service` (mosipid/biosdk-server:1.3.0) + `biosdk-client` jar (Maven profile) | 8083 |
| Masterdata `idschema/latest` | ID schema used to validate create/update requests | WireMock `masterdata.json` (MOSIP sample schema id 1001, v0.1) | 8082 |
| Kernel ID generator `/v1/idgenerator/uin` | new UIN for `POST /draft/create` without a UIN | WireMock, always returns `2838501739` | 8082 |
| VID service | VID→UIN lookups, VIDs of a UIN, draft VID create/activate | WireMock: VID `2092493569127145` → `7067209349` (`samples/set-2`), any other VID → `3649229809`; no linked VIDs; draft VID `5712817694382350` | 8082 |
| PMS partner manager | online-verification partner list for credential issuance | WireMock: one partner `mpartner-default-auth` | 8082 |
| Credential request generator | credential issuance (scheduled job) and cancellation | WireMock: random `requestId` | 8082 |
| Audit manager | audit event on every API call | WireMock: accepts all | 8082 |
| WebSub hub | VID-event subscription at startup; publishing identity/auth-type events | WireMock: `202 Accepted` | 8082 |
| `kernel-ref-idobjectvalidator` jar | reference-data validation (added to the image at runtime) | disabled locally (`referenceValidator=` → built-in no-op validator) | — |

### Docker images

| Service | Image | Container name | Ports (host:container) |
|---------|-------|----------------|------------------------|
| `database` | `postgres:16-bookworm` | `idrepo_database` | 5455:5432 |
| `config-server` | `mosipid/config-server:latest` | `idrepo_config_server` | 51000:51000 |
| `mock-service` | `wiremock/wiremock:3.13.1` | `idrepo_mock_service` | 8082:8082 |
| `biosdk-service` | `mosipid/biosdk-server:1.3.0` | `idrepo_biosdk_service` | 8083:9099 |
| `object-store` | `adobe/s3mock:5.2.3` | `idrepo_object_store` | 9090:9090 |

`biosdk-service` waits until `mock-service` is healthy, because it downloads `mock-sdk.zip` from WireMock when it starts.

---

## 5. Local Setup Steps

Run all commands from a terminal. Paths assume both repositories are cloned into the same parent folder (`~/dev` below); adjust as needed.

### Step 1 — Clone the repositories

```bash
cd ~/dev
git clone https://github.com/mosip/id-repository
git clone -b release-1.3.1 https://github.com/mosip/mosip-config
```

*What it does:* gets the service source and the configuration repository.
Use `mosip-config` branch **`release-1.3.1`**, which matches this service's version (1.3.1). `release-1.3.x` is missing properties the 1.3.1 code requires (`mosip.idrepo.idvid.metadata.id`, `mosip.idrepo.idvid.metadata.version`), and the service then fails at startup with *Could not resolve placeholder*.
Do **not** edit `mosip-config`. All local overrides live in this repository.

### Step 2 — Build

```bash
cd ~/dev/id-repository/id-repository
mvn clean install -DskipTests -Dgpg.skip=true -Dmaven.javadoc.skip=true -pl id-repository-identity-service -am
```

*What it does:* builds `id-repository-core` and installs it to your local Maven repository, then builds the identity service. The parent POM is in `id-repository/id-repository`, not the git root. See [section 8](#8-build-instructions) for tests.

### Step 3 — Prepare the mock biometric SDK (once)

```bash
cd ~/dev/id-repository/id-repository/id-repository-identity-service/local-dev-setup

# macOS / Linux
chmod +x prepare-biosdk-mock-lib.sh
./prepare-biosdk-mock-lib.sh

# Windows (cmd or PowerShell)
prepare-biosdk-mock-lib.bat
```

*What it does:* downloads `io.mosip.mock.sdk:mock-sdk:1.3.0-beta.1` (`jar-with-dependencies`) from Maven Central and zips it to `docker-compose/wiremock/__files/mock-sdk.zip` (~171 MB, git-ignored). WireMock serves this file at `GET /downloads/mock-sdk.zip`, and `biosdk-service` loads it on startup. Run it again only if the file is deleted.

### Step 4 — Point the config server at your `mosip-config` clone

```bash
cd docker-compose
cp .env.example .env          # Windows cmd: copy .env.example .env
```

Edit `.env` and set the **absolute** path of your `mosip-config` clone (forward slashes on Windows):

```properties
MOSIP_CONFIG_DIR=/home/you/dev/mosip-config        # e.g. C:/dev/mosip-config on Windows
```

*What it does:* Docker Compose reads `.env` automatically and mounts that folder into the config server. `docker compose` refuses to start if the variable is not set.

### Step 5 — Start the backing services

```bash
docker compose up -d
docker compose ps
```

*What it does:* starts the five containers. Data is kept in the named volumes `idrepo-db-data` and `idrepo-object-data` across restarts and `docker compose down`; see [Reset everything](#11-troubleshooting). On the **first** start (empty volume), `database` runs `init-db/01-init-idrepo.sh`, which:
1. runs `db_scripts/mosip_idrepo/role_dbuser.sql`, `db.sql`, `ddl.sql` and `grants.sql`, in the same order as `db_scripts/mosip_idrepo/deploy.sh`. This creates database `mosip_idrepo`, schema `idrepo`, 17 tables and role `idrepouser` with password `mosip123`;
2. runs `init-db/sql/seed-salts.sql`, which adds 1000 rows each to `idrepo.uin_hash_salt` and `idrepo.uin_encrypt_salt`.

Wait until `docker compose ps` shows every service running, with `database` and `mock-service` healthy. Then run the checks in [section 10.1](#101-backing-services).

### Step 6 — Run the Identity Service

```bash
cd ~/dev/id-repository/id-repository/id-repository-identity-service
mvn -Plocal-dev spring-boot:run
```

*What it does:* starts the service with the `local-dev` Maven profile, which:
- adds the auth adapter and biosdk client jars,
- activates the `localdev` Spring profile,
- adds the required JVM `--add-opens` flags.

It's ready when the log shows `Started IdRepoBootApplication in … seconds` (about 15 s). See [section 9](#9-run-instructions) for IDE options.

### Step 7 — Verify

Follow [section 10](#10-verification--health-checks): the health check, then create and retrieve an identity with the sample requests.

To use Swagger UI, open **<http://localhost:8082/dev-login>** first. It sets the auth cookie and opens Swagger; without it every call returns `401` ([section 10.5](#105-swagger-ui)).

---

## 6. Configuration

### 6.1 How configuration is resolved

1. `src/main/resources/bootstrap.properties` (unchanged) sets `spring.application.name=id-repository`, `spring.cloud.config.name=application,id-repository`, port `8090` and servlet path `/idrepository/v1/identity`.
2. With Spring profile `localdev` active, Spring Cloud also loads **`bootstrap-localdev.properties`**:

   ```properties
   spring.cloud.config.uri=http://localhost:51000/config
   spring.cloud.config.label=master
   spring.cloud.config.profile=default,localdev
   spring.cloud.config.fail-fast=true
   spring.cloud.loadbalancer.enabled=false
   ```

   - `profile=default,localdev`: the config server returns `application-default.properties` and `id-repository-default.properties` from `mosip-config`, and **then** `id-repository-localdev.properties` from `local-dev-setup/config/`, which takes precedence.
   - `fail-fast=true`: the service stops immediately if the config server is unreachable.
   - `loadbalancer.enabled=false`: `kernel-auth-adapter` brings in Spring Cloud LoadBalancer, which would otherwise treat `localhost` as a service name and fail outgoing calls (same setting as the id-authentication reference).
3. The config server container is started with `SPRING_CLOUD_CONFIG_SERVER_NATIVE_SEARCH_LOCATIONS=file:/mosip-config,file:/local-config`. `/mosip-config` is your clone and `/local-config` is `local-dev-setup/config`.
4. The service also fetches **files** from the config server: `identity-mapping.json` and `mosip-cbeff.xsd`, via `http://localhost:51000/config/id-repository/localdev/master/<file>`. Both come from your `mosip-config` clone.

The service checks this file order in its health endpoint: `components.clientConfigServer.details.propertySources` lists the overlay first.

### 6.2 The local overlay — `local-dev-setup/config/id-repository-localdev.properties`

This is the only configuration file you normally edit. Its values:

| Group | Property | Value |
|-------|----------|-------|
| Hosts | `mosip.api.internal.host`, `mosip.api.public.host` | `localhost` |
| Swagger UI | `openapi.idRepoIdentityServiceServer.servers[0].url` | `http://localhost:8090/idrepository/v1/identity` (mosip-config builds `https://<host>` with no port, so "Try it out" failed with *Failed to fetch*) |
| Keycloak / auth | `keycloak.internal.url`, `keycloak.external.url` | `http://localhost:8082` |
| | `auth.server.admin.offline.comp.token.validate` | `false` (validate tokens online against the userinfo stub) |
| MOSIP services → WireMock | `mosip.kernel.authmanager.url`, `mosip.kernel.masterdata.url`, `mosip.kernel.syncdata.url`, `mosip.kernel.keymanager.url`, `mosip.kernel.auditmanager.url`, `mosip.kernel.idgenerator.url`, `mosip.kernel.notification.url`, `mosip.idrepo.vid.url`, `mosip.idrepo.credrequest.generator.url`, `mosip.idrepo.credential.service.url`, `mosip.pms.partnermanager.url`, `mosip.pms.policymanager.url`, `mosip.datashare.url`, `mosip.websub.url` | `http://localhost:8082` |
| Self URL (WebSub callback) | `mosip.idrepo.identity.url` | `http://localhost:8090` |
| Biometric SDK | `mosip.mock.biosdk.url`, `mosip.idrepo.biosdk.url` | `http://localhost:8083` |
| Request validation | `mosip.idrepo.identity.max-request-time-deviation-seconds` | `315360000` (accept any `requesttime`, so samples work as-is) |
| | `mosip.kernel.idobjectvalidator.referenceValidator` | *(empty)* → built-in no-op validator |
| Database | `mosip.idrepo.db.url` / `mosip.idrepo.db.port` | `localhost` / `5455` |
| | `db.dbuser.password` | `mosip123` (user `idrepouser` comes from `mosip-config`) |
| Object store | `object.store.s3.url` | `http://localhost:9090` |
| | `s3.accesskey` / `s3.secretkey` / `s3.region` | `localdev` / `localdev` / `us-east-1` (S3Mock accepts any credentials) |
| Dummy secrets (normally Kubernetes secrets) | `mosip.idrepo.client.secret`, `mosip.creser.client.secret`, `mosip.idrepo.credential-req-generator.auth.secret-key`, `idrepo.websub.vid.credential.update.secret` | `localdev` |
| | `mosip.idrepo.credential-req-generator.auth.app-id` / `.client-id` | `crereq` / `mosip-crereq-client` |
| | `mosip.idrepo.credential.auth.app-id` / `.client-id` | `creser` / `mosip-creser-client` |
| | `mosip.kernel.uin.salt`, `mosip.kernel.partnercode.salt` | fixed dev values |

With `mosip-config` `release-1.3.1`, every `${...}` placeholder in `application-default.properties` and `id-repository-default.properties` resolves. The config server re-reads files on each request, so after editing the overlay you only need to **restart the service**.

### 6.3 Values you must provide

| What | Where | Value |
|------|-------|-------|
| Absolute path of your `mosip-config` clone | `local-dev-setup/docker-compose/.env` → `MOSIP_CONFIG_DIR` | e.g. `/home/you/dev/mosip-config` or `C:/dev/mosip-config` |

Nothing else needs changing for a default setup.

---

## 7. Environment Variables

### Docker Compose (`local-dev-setup/docker-compose/.env`)

| Variable | Required | Description |
|----------|----------|-------------|
| `MOSIP_CONFIG_DIR` | **yes** | Absolute path to the `mosip-config` clone (`release-1.3.1`). Mounted read-only at `/mosip-config` in `config-server`. |

### Set inside `docker-compose.yml` (no change needed)

| Service | Variable | Value | Meaning |
|---------|----------|-------|---------|
| database | `POSTGRES_USER` / `POSTGRES_PASSWORD` | `postgres` / `mosip123` | superuser |
| database | `IDREPO_DB_PASSWORD` | `mosip123` | password for role `idrepouser` (used by `01-init-idrepo.sh`); must match `db.dbuser.password` in the overlay |
| config-server | `SPRING_PROFILES_ACTIVE` | `native` | serve from the filesystem |
| config-server | `SPRING_CLOUD_CONFIG_SERVER_NATIVE_SEARCH_LOCATIONS` | `file:/mosip-config,file:/local-config` | `mosip-config` + overlay |
| config-server | `SPRING_CLOUD_CONFIG_SERVER_ACCEPT_EMPTY`, `..._GIT_*`, `SERVER_PORT=51000`, `MANAGEMENT_*`, `SPRING_SECURITY_ENABLED=false` | | same as the id-authentication reference |
| mock-service | `JAVA_OPTS` | `-Xms256m -Xmx512m` | WireMock heap |
| biosdk-service | `biosdk_zip_file_path` | `http://mock-service:8082/downloads/mock-sdk.zip` | where to fetch the SDK |
| biosdk-service | `biosdk_bioapi_impl` | `io.mosip.mock.sdk.impl.SampleSDKV2` | SDK implementation class |
| object-store | `COM_ADOBE_TESTING_S3MOCK_STORE_INITIAL_BUCKETS` | `idrepo` | bucket created at startup |
| object-store | `COM_ADOBE_TESTING_S3MOCK_STORE_ROOT`, `..._RETAIN_FILES_ON_EXIT` | `/home/cnb/s3mock`, `true` | keep objects on volume `idrepo-object-data`, mounted at `/home/cnb` (owned by the image's uid 1000) |

### Identity Service

No environment variables are required. `spring.profiles.active=localdev` is set by the `local-dev` Maven profile (`spring-boot.run.profiles`). In an IDE, set it yourself ([section 9](#9-run-instructions)).

---

## 8. Build Instructions

All Maven commands run from `id-repository/id-repository` (the parent POM).

```bash
# core + identity service, no tests (what the setup needs)
mvn clean install -DskipTests -Dgpg.skip=true -Dmaven.javadoc.skip=true -pl id-repository-identity-service -am

# identity-service unit tests
mvn test -pl id-repository-identity-service -Dgpg.skip=true

# check the local-dev profile's classpath (should list kernel-auth-adapter and biosdk-client)
mvn dependency:tree -Plocal-dev -pl id-repository-identity-service -Dincludes=io.mosip.kernel:kernel-auth-adapter,io.mosip.biosdk:biosdk-client
```

- Rebuild `id-repository-core` (`-am`, or `mvn install -pl id-repository-core -DskipTests`) after changing core code. The service uses the installed core jar.
- The `local-dev` profile only matters when **running**. Building without it produces the normal deployable artifact, which doesn't contain the auth adapter or biosdk client.
- Known: 1 of 321 unit tests (`VidDraftHelperTest.activeDraftVidExceptionTest`) fails on the current branch, with or without these changes. See [section 13](#13-important-notes--known-limitations).

---

## 9. Run Instructions

The backing services ([Step 5](#step-5--start-the-backing-services)) must be running first.

### Option A — Maven (recommended, verified)

```bash
cd id-repository/id-repository/id-repository-identity-service
mvn -Plocal-dev spring-boot:run
```

Stop it with **Ctrl+C**. `spring-boot:run` starts the service in a separate JVM. If you kill Maven some other way and port 8090 stays busy, stop the leftover `java` process running `IdRepoBootApplication`.

### Option B — IntelliJ IDEA

1. **File → Open** `id-repository/id-repository` as a Maven project.
2. In the **Maven** tool window, under **Profiles**, tick **`local-dev`**, then **Reload All Maven Projects**.
3. Create a run configuration for `io.mosip.idrepository.identity.IdRepoBootApplication` with:
   - **Active profiles:** `localdev` (or VM option `-Dspring.profiles.active=localdev`)
   - **VM options:** `--add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.reflect=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.time=ALL-UNNAMED --add-opens java.base/sun.reflect.annotation=ALL-UNNAMED`
   - **Working directory:** `id-repository-identity-service`

### Option C — VS Code

1. Install the *Extension Pack for Java*, then open `id-repository/id-repository`.
2. Enable the `local-dev` Maven profile for the workspace: Maven sidebar → `id-repository-identity-service` → *Select Profiles*.
3. Add to `.vscode/launch.json`:

   ```json
   {
     "type": "java",
     "name": "Identity Service (localdev)",
     "request": "launch",
     "mainClass": "io.mosip.idrepository.identity.IdRepoBootApplication",
     "projectName": "id-repository-identity-service",
     "vmArgs": "-Dspring.profiles.active=localdev --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.reflect=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.time=ALL-UNNAMED --add-opens java.base/sun.reflect.annotation=ALL-UNNAMED"
   }
   ```

> The Spring profile must be **`localdev`**, never `local`. `kernel-auth-adapter` 1.3.1 treats a profile named `local` specially and rejects every token with `KER-ATH-007` *Offline Auth Not Supported*.

### Service ports and endpoints

| | Value |
|---|---|
| Port | `8090` |
| Base path | `http://localhost:8090/idrepository/v1/identity` |
| Health | `GET /actuator/health` (no token needed) |
| Swagger UI | `/swagger-ui/index.html` |
| OpenAPI | `/v3/api-docs` |

| Method & path (under the base path) | Purpose |
|---|---|
| `POST /` | Create identity |
| `PATCH /` | Update identity / status |
| `GET /idvid/{id}?type=demo\|bio\|all\|metadata&idType=UIN\|VID\|ID\|HANDLE` | Retrieve (`*ExtractionFormat` query params for biometric templates) |
| `POST /idvid/`, `POST /idvid/v2` | Retrieve with the id in the body |
| `GET /rid/{individualId}` | Latest RID |
| `POST /idvid-metadata/search` | RID + created/updated timestamps |
| `GET /{individualId}/update-counts` | Remaining updates per attribute |
| `POST /authtypes/status`, `GET /authtypes/status/individualIdType/{type}/individualId/{id}`, `GET /authtypes/status/{id}` | Auth-type lock / unlock / status |
| `POST /draft/create/{rid}`, `PATCH /draft/update/{rid}`, `GET /draft/publish/{rid}`, `DELETE /draft/discard/{rid}`, `HEAD /draft/{rid}`, `GET /draft/{rid}`, `PUT /draft/extractbiometrics/{rid}`, `GET /draft/uin/{UIN}` | Draft lifecycle |
| `POST /callback/vid_credential_status_update` | WebSub callback (called by the hub, not by you) |

---

## 10. Verification / Health Checks

### 10.1 Backing services

```bash
cd local-dev-setup/docker-compose
docker compose ps                                                     # all running; database + mock-service healthy

# config server: overlay listed first, then mosip-config files
curl -s http://localhost:51000/config/id-repository/default,localdev/master
# the files the service downloads at startup (expect HTTP 200)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:51000/config/id-repository/localdev/master/identity-mapping.json
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:51000/config/id-repository/localdev/master/mosip-cbeff.xsd

curl -s http://localhost:8082/__admin/health                          # WireMock up
curl -s http://localhost:8082/__admin/mappings | grep -c '"name"'     # 19 stubs loaded
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8083/biosdk-service/   # biosdk server answers
curl -s "http://localhost:9090/idrepo?list-type=2"                    # S3 bucket "idrepo" exists

# database: 17 tables, 1000 salts
docker exec idrepo_database psql -U postgres -d mosip_idrepo -tAc "select count(*) from information_schema.tables where table_schema='idrepo'"
docker exec idrepo_database psql -U postgres -d mosip_idrepo -tAc "select count(*) from idrepo.uin_hash_salt"
```

### 10.2 Service startup

Look for these in the service log:
- `Successfully registered SDK : sample2, BiometricFunction: ...` (biometric SDK reached biosdk-service)
- `subscribed event topic: VID_CRED_STATUS_UPDATE` (WebSub subscription)
- `Started IdRepoBootApplication in ... seconds`

```bash
curl -s http://localhost:8090/idrepository/v1/identity/actuator/health
# → {"status":"UP","components":{"clientConfigServer":{"status":"UP",...},"db":{"status":"UP",...},...}}
```

The `discoveryComposite` component reports `UNKNOWN` locally. That's expected (no service registry) and doesn't affect the overall `UP`.

### 10.3 Authentication and API calls

Every endpoint except health needs a JWT carrying the endpoint's role. MOSIP's auth adapter reads it from a **cookie named `Authorization`**. An `Authorization: Bearer` header is **ignored** and results in `KER-ATH-401`.

`samples/dev-token.txt` is a long-lived dev token:
- issuer `http://localhost:8082/auth/realms/mosip`, `azp` `mosip-idrepo-client`, expiry 2100-01-01
- roles `ID_REPOSITORY`, `REGISTRATION_PROCESSOR`, `RESIDENT`, `ID_AUTHENTICATION`, `REGISTRATION_ADMIN`, `REGISTRATION_OFFICER`, `REGISTRATION_SUPERVISOR`

Its signature is never checked locally. The mocked Keycloak userinfo endpoint accepts any token, and the auth adapter then reads roles and audience from the token's claims.

```bash
cd id-repository/id-repository/id-repository-identity-service/local-dev-setup
TOKEN=$(cat samples/dev-token.txt)                    # PowerShell: $TOKEN = Get-Content samples\dev-token.txt
BASE=http://localhost:8090/idrepository/v1/identity   # PowerShell: $BASE = "http://localhost:8090/idrepository/v1/identity"
# (on Windows PowerShell call curl.exe, not the curl alias)

# 0. without a token → 401
curl -s -o /dev/null -w "%{http_code}\n" $BASE/idvid/3649229809

# 1. create UIN 3649229809 with one demographic document → "status":"ACTIVATED"
curl -s -X POST $BASE/ -b "Authorization=$TOKEN" -H "Content-Type: application/json" --data @samples/add-identity.json

# 2. retrieve everything (identity + document from the object store)
curl -s "$BASE/idvid/3649229809?type=all" -b "Authorization=$TOKEN"

# 3. retrieve by VID (the stub resolves every VID to 3649229809, except set-2's 2092493569127145)
curl -s "$BASE/idvid/4153960163175407?type=demo" -b "Authorization=$TOKEN"

# 4. update the phone number, then read it back → "phone":"9123456780"
curl -s -X PATCH $BASE/ -b "Authorization=$TOKEN" -H "Content-Type: application/json" --data @samples/update-identity.json
curl -s "$BASE/idvid/3649229809" -b "Authorization=$TOKEN"

# 5. other read APIs
curl -s "$BASE/rid/3649229809" -b "Authorization=$TOKEN"
curl -s "$BASE/3649229809/update-counts" -b "Authorization=$TOKEN"
curl -s -X POST "$BASE/idvid-metadata/search" -b "Authorization=$TOKEN" -H "Content-Type: application/json" \
  -d '{"id":"mosip.idrepo.idvid.metadata","version":"1.0","requesttime":"2026-10-22T10:00:00.000Z","request":{"individualId":"3649229809","idType":"UIN"}}'

# 6. lock fingerprint auth, then read lock status (note: "requestTime", camelCase, on this endpoint)
curl -s -X POST "$BASE/authtypes/status" -b "Authorization=$TOKEN" -H "Content-Type: application/json" \
  -d '{"id":"mosip.idrepo.auth.type.status","version":"v1","requestTime":"2026-10-22T10:00:00.000Z","individualId":"3649229809","individualIdType":"UIN","request":[{"authType":"bio","authSubType":"FINGER","locked":true}]}'
curl -s "$BASE/authtypes/status/individualIdType/UIN/individualId/3649229809" -b "Authorization=$TOKEN"
```

**Draft lifecycle**: a new identity whose UIN comes from the ID-generator stub (`2838501739`):

```bash
RID=10001100010000320261022101000
curl -s -X POST "$BASE/draft/create/$RID" -b "Authorization=$TOKEN"                     # → DRAFTED
curl -s -X PATCH "$BASE/draft/update/$RID" -b "Authorization=$TOKEN" -H "Content-Type: application/json" \
  -d '{"id":"mosip.id.update","version":"v1","requesttime":"2026-10-22T10:10:00.000Z","request":{"registrationId":"'$RID'","identity":{"IDSchemaVersion":0.1,"UIN":"2838501739","fullName":[{"language":"eng","value":"Ravi Menon"}],"dateOfBirth":"1985/06/30","gender":[{"language":"eng","value":"Male"}],"addressLine1":[{"language":"eng","value":"4 Hill St"}],"region":[{"language":"eng","value":"Rabat Sale Kenitra"}],"province":[{"language":"eng","value":"Kenitra"}],"city":[{"language":"eng","value":"Kenitra"}],"zone":[{"language":"eng","value":"Ben Mansour"}],"phone":"9000000001","email":"ravi@example.com"}}}'
curl -s -o /dev/null -w "%{http_code}\n" -I "$BASE/draft/$RID" -b "Authorization=$TOKEN" # → 200 (draft exists)
curl -s "$BASE/draft/publish/$RID" -b "Authorization=$TOKEN"                             # → ACTIVATED, metadata.vid = 5712817694382350
```

**Update draft** of an existing identity. The query parameter is `UIN`, in capitals. A lowercase `?uin=` is silently ignored and starts a new-registration draft instead.

```bash
RID=10001100010000420261022102000
curl -s -X POST "$BASE/draft/create/$RID?UIN=3649229809" -b "Authorization=$TOKEN"     # → DRAFTED (copy of the identity)
curl -s "$BASE/draft/uin/3649229809" -b "Authorization=$TOKEN"                         # → drafts: [{rid, createdDTimes, attributes}]
curl -s -X DELETE "$BASE/draft/discard/$RID" -b "Authorization=$TOKEN"                 # → DISCARDED (or /draft/publish/$RID to apply it)
```

### 10.4 Side effects worth checking

```bash
# records, history, credential issuance (rows reach REQUESTED within ~10 s via the scheduled job)
docker exec idrepo_database psql -U postgres -d mosip_idrepo -c "select count(*) from idrepo.uin"
docker exec idrepo_database psql -U postgres -d mosip_idrepo -c "select partner_id, status from idrepo.credential_request_status"
# document stored under <uinHash>/Demographics/<uuid>.txt
curl -s "http://localhost:9090/idrepo?list-type=2"
# every outbound call the service made
docker compose logs -f mock-service
```

### 10.5 Swagger UI

Open **<http://localhost:8082/dev-login>** (not the Swagger URL directly). It sets the `Authorization` cookie to the dev token and redirects you to Swagger UI, so "Try it out" works on every endpoint. Cookies ignore the port, so a cookie set by WireMock on `:8082` is sent to the service on `:8090`. It lasts a year. Open `/dev-login` again after clearing your cookies.

Swagger's **Authorize** button doesn't help here, because the auth adapter accepts the token only as a cookie, and Swagger UI can't set cookies.

### 10.6 Rules for writing your own requests

- **UIN** (create): 10 digits that pass MOSIP's UIN rules (checksum, no sequences or repeats). Valid spares: `3005385647`, `3173490439`, `6598506701`, `4635043897`, `4692194352`, `4270538493` (`2838501739` is what the ID-generator stub returns for drafts). A UIN with a wrong check digit fails with `IDR-IDC-002 Invalid Input Parameter - UIN`.
- **Ready-made data:** `samples/add-identity.json` and `update-identity.json` (UIN `3649229809`) follow section 10.3. [`samples/set-2/`](local-dev-setup/samples/set-2/README.md) is a second, numbered set (UINs `7067209349`, `9512837641`, and `2838501739` via a draft) with its run order and expected results. Each file works once per empty database: run `docker compose down -v` and `up -d` to reuse them.
- **VID** for lookups: any 16-digit valid VID, e.g. `4153960163175407`. The stub maps every VID to `3649229809`, except `2092493569127145`, which maps to set-2's `7067209349`.
- **`registrationId` (RID)**: 29 digits, `<5-digit centre><5-digit machine><5-digit sequence><yyyyMMddHHmmss>`. It must be **unique per request**: create, every update and every draft each need a new RID, or you get `IDR-IDC-012 Record already exists`.
- **`requesttime`**: any value works locally (the overlay widens the allowed deviation). `POST /authtypes/status` uses `requestTime` (camelCase).
- **Identity fields** must follow the ID schema served by the masterdata stub: MOSIP sample schema v0.1. New registrations need `IDSchemaVersion, UIN, fullName, dateOfBirth|age, gender, addressLine1, region, province, city, zone`. `dateOfBirth` uses `yyyy/MM/dd`. Multi-language fields are `[{"language":"eng","value":"..."}]`.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `docker: command not found` / not recognized, right after installing Docker Desktop | terminal (or IDE) was opened before the install, so it has the old `PATH` | Open a new terminal or restart the IDE. Docker Desktop must also be running (whale icon) |
| `docker compose up`: *Set MOSIP_CONFIG_DIR in .env…* | `.env` missing or variable not set | Step 4 |
| Startup: `Could not resolve placeholder 'mosip.idrepo.idvid.metadata.id'` (or another key) | `mosip-config` branch doesn't match the code | `git -C <mosip-config> checkout release-1.3.1` |
| Startup: `FileNotFoundException: http://localhost:51000/config/id-repository/localdev/master/mosip-cbeff.xsd` (or `identity-mapping.json`) | config server can't see your clone (wrong `MOSIP_CONFIG_DIR`, or not a full clone) | Fix `.env`, run `docker compose up -d config-server`, then check with the curl in 10.1 |
| Startup: config server connection refused (fails fast) | `config-server` not running | `docker compose ps`; `docker compose logs config-server` |
| Startup: `SDK_REGISTRY_EMPTY` or biometric provider errors | `biosdk-service` not up: `mock-sdk.zip` missing, or it started before WireMock | Run Step 3, then `docker compose restart biosdk-service`; `docker compose logs biosdk-service` |
| Startup: `ClassNotFoundException ... IdObjectReferenceValidator` | overlay not applied (profile not `localdev`) | Run with `-Plocal-dev`, or set `spring.profiles.active=localdev` in the IDE |
| Startup: `ClassNotFoundException` for auth adapter or `io.mosip.biosdk.client...` classes | `local-dev` Maven profile not active | `mvn -Plocal-dev ...` / tick the profile in the IDE |
| 503 / LoadBalancer errors on outgoing calls | `spring.cloud.loadbalancer.enabled=false` not applied | Same as above: the `localdev` profile must be active |
| `KER-ATH-401 Authentication Failed` | token sent as a Bearer header, or not sent | curl: send `-b "Authorization=<token>"`. Swagger UI: open <http://localhost:8082/dev-login> first |
| Every token rejected with `KER-ATH-007` *Offline Auth Not Supported* | Spring profile named `local` | Use `localdev` |
| `KER-ATH-403 Forbidden` / access denied | token lacks the endpoint's role or audience | Use `samples/dev-token.txt` (has all identity-service roles) |
| `IDR-IDC-012 Record already exists` | RID or UIN already used. A RID is single-use across creates, updates and drafts (a published draft's RID counts) | New RID (and new UIN for creates), or reset the DB (below) |
| `IDR-IDC-007 No Record(s) found` | the identity was never created (empty DB after a reset), or `GET /draft/{rid}` after the draft was published or discarded (both delete the draft) | Create it first (`POST /`); for drafts this is expected |
| Draft publish fails: `IDR-IDC-001 Missing Input Parameter - identity/IDSchemaVersion` | the draft was created **without** `UIN`, so it's a new-registration draft holding only the stub UIN `2838501739` | `DELETE /draft/discard/{rid}`, then create it again with the `UIN` field filled (update draft), or `PATCH /draft/update` all required fields first (new registration) |
| `GET /draft/uin/{UIN}` returns `drafts: null` right after creating a draft | draft created with lowercase `?uin=` or an empty `UIN` field, so it went to a new stub UIN | Use `?UIN=` (capitals) |
| Swagger "Try it out": *Failed to fetch* and the request URL is `https://localhost/...` | the service was started before the overlay set the Swagger server URL, or without the `localdev` profile | Restart the service with `-Plocal-dev`, then reload the Swagger page |
| `IDR-IDC-002 Invalid Input Parameter - documents/0/value` | biometric document isn't a schema-valid CBEFF | Use a CBEFF that validates against `mosip-cbeff.xsd` |
| `IDR-IDC-004 Unknown error` on `PATCH /` with `documents` | known code bug for identities without stored biometrics ([section 13](#13-important-notes--known-limitations)) | Send the update without `documents` |
| DB init didn't run / schema changes not picked up | init scripts only run on an **empty** volume | `docker compose down -v && docker compose up -d` |
| `01-init-idrepo.sh: $'\r': command not found` | script has CRLF line endings (checked out before `.gitattributes` applied, or edited with a CRLF editor) | Convert the file to LF (e.g. `dos2unix local-dev-setup/docker-compose/init-db/01-init-idrepo.sh`, or set the editor's line endings to LF), then `docker compose down -v && docker compose up -d` |
| Startup: `Web server failed to start. Port 8090 was already in use` (or port still busy after stopping) | another instance of the service is still running (an earlier `spring-boot:run`, an IDE run, or its leftover JVM) | Stop it with Ctrl+C in its terminal, or stop the `java` process running `IdRepoBootApplication` |
| Port already in use (5455/51000/8082/8083/9090) | another local service | Stop it, or change the host port in `docker-compose.yml` **and** the matching URL in the overlay |

**Stop, restart, keep data.** Run these in `local-dev-setup/docker-compose`. Database rows and S3 documents live in the named volumes `idrepo-db-data` and `idrepo-object-data`, so none of these lose data:
```bash
docker compose restart                 # all containers (or: docker compose restart database)
docker compose stop                    # stop; resume with: docker compose start
docker compose down                    # remove containers; recreate with: docker compose up -d
```
The containers have no restart policy, so after a reboot start Docker Desktop and run `docker compose start`. The service on 8090 reconnects to restarted containers by itself. If calls fail afterwards, restart it.

**Reset everything** (deletes all local identities and documents):
```bash
cd local-dev-setup/docker-compose
docker compose down -v
docker compose up -d
```
`-v` removes both volumes together. Always reset them together: a database row whose document is missing from S3 fails on retrieve with `IDR-IDS-004`.

---

## 12. Issues Encountered During Implementation (and Resolutions)

| # | Issue | Resolution |
|---|-------|------------|
| 1 | Service failed with `Could not resolve placeholder 'mosip.idrepo.idvid.metadata.id'` using `mosip-config` `release-1.3.x` | `release-1.3.1` defines `mosip.idrepo.idvid.metadata.id/version`; the setup requires that branch. A diff of every no-default `@Value` property against `release-1.3.1` + overlay shows nothing missing. |
| 2 | `CbeffImpl` init failed: `mosip-cbeff.xsd` not found | It's fetched from the config server at startup; a full `mosip-config` clone contains it. |
| 3 | `kernel-auth-adapter` rejects all tokens when the profile is named `local` (deprecated offline-local path) | Spring profile named `localdev`. |
| 4 | Incoming requests returned `KER-ATH-401` with a Bearer header | The auth adapter reads the JWT from the `Authorization` **cookie**; documented, and samples use `-b`. |
| 5 | No Keycloak locally, but every endpoint is role-protected | Online token validation (`auth.server.admin.offline.comp.token.validate=false`) against a WireMock userinfo stub, plus a static dev JWT carrying all roles. The service's own token comes from a WireMock token stub. |
| 6 | All persistence goes through the remote keymanager | WireMock echo stub. It round-trips correctly through `encrypt`, `encryptWithSalt`, `decrypt` and `decryptWithSalt`, but stores data unencrypted (base64). |
| 7 | Filesystem object store excluded by `IdRepoBootApplication`'s component scan; S3 mandatory | S3-compatible container. MinIO images are no longer on Docker Hub and the binary download returns 410, so **Adobe S3Mock 5.2.3** is used. |
| 8 | Startup fails with `SDK_REGISTRY_EMPTY` without a biometric SDK | `biosdk-client` (Maven profile) + `biosdk-service` container with the mock SDK, as in the reference. |
| 9 | `mosip-config` sets `IdObjectReferenceValidator`, whose jar is only added to the container image at runtime | Blanked in the overlay → built-in no-op validator (MOSIP's own developer guide also disables it). |
| 10 | Requests are rejected if `requesttime` is more than 60 s off, so static samples would expire | Overlay widens `mosip.idrepo.identity.max-request-time-deviation-seconds`. |
| 11 | Salt tables are normally filled by the separate salt-generator job | `seed-salts.sql` seeds ids 0–999 (base64 of 16 bytes, like the generator), deterministically. |
| 12 | Postgres entrypoint *sources* non-executable `.sh` files (common on Windows checkouts) | `01-init-idrepo.sh` runs in a subshell so it's safe whether sourced or executed; `.gitattributes` keeps it LF. |
| 13 | The reference's WireMock healthcheck interval is 500 s, and `biosdk-service` waits for that check to pass, which can delay its start by minutes | Interval 10 s. |
| 14 | Swagger "Try it out" failed (*Failed to fetch*): mosip-config sets the Swagger server URL to `https://localhost`, with no port | Overlay sets `openapi.idRepoIdentityServiceServer.servers[0].url=http://localhost:8090/idrepository/v1/identity`. |
| 15 | Swagger calls returned `KER-ATH-401`: the auth adapter accepts the token only as a cookie (raw and Bearer headers both fail), Swagger UI can't set cookies, and pasting into the DevTools console is blocked by default | WireMock stub `GET /dev-login` sets the `Authorization` cookie and redirects to Swagger. Cookies ignore ports, so `:8090` receives it. |
| 16 | Data was lost on `docker compose down` / `up`: Postgres used an anonymous volume, and S3Mock kept objects in a temp dir | Named volumes `idrepo-db-data` and `idrepo-object-data`. S3Mock's store root is set under `/home/cnb` (writable by the image's uid 1000) and `retainFilesOnExit=true`. S3Mock records absolute file paths, so the root must stay fixed. |
| 17 | `POST /draft/create/{rid}?uin=...` silently started a new-registration draft | The query parameter is `UIN` (case-sensitive); documented here and in the module `CLAUDE.md`. |

---

## 13. Important Notes / Known Limitations

### How this setup was verified

Verified on 2026-10-22 on Windows 11 with Docker Desktop 29.9 (Compose v5.6), starting from an empty volume: `docker compose up -d`, then `mvn -Plocal-dev spring-boot:run`. Everything in section 10 passed:
- all five containers up, with the init script creating 17 tables and 1000 salts
- the config server serving the overlay plus both `mosip-config` files under `/config`
- biosdk-service downloading the mock SDK from `mock-service`, and S3Mock creating the `idrepo` bucket
- startup, with the SDK registered and the WebSub subscription made
- health, `401` without a token, create, retrieve by UIN and by VID, update, RID, update counts, metadata search, auth-type lock and lock status
- draft create, update, HEAD and publish, returning draft VID `5712817694382350`
- credential rows reaching `REQUESTED`, and the document stored in S3Mock
- every endpoint in the table in section 9 except the WebSub callback, including `POST /idvid/`, `/idvid/v2`, retrieve by RID, update drafts (`?UIN=`), extract biometrics, discard, and a status change to `BLOCKED` and back
- Swagger UI "Try it out" after `/dev-login`
- data surviving `docker compose restart` and `down` / `up -d` (named volumes)
- both sample sets end to end: `samples/` (section 10.3) and all 8 steps of `samples/set-2`, including both VID stubs

Re-verified on 2026-10-23 after moving the setup to a second clone of the repository: containers recreated from the new location, a fresh build, then both sample sets passed.

Before Docker was available, the same checks had also passed against each service run natively (portable PostgreSQL 16, `kernel-config-server:1.3.1`, the WireMock jar, `biosdk-services:1.3.0`, the S3Mock jar).

### Functional limitations

- **No real encryption.** See the warning in section 1.
- **Biometric template extraction was not verified end to end.** The SDK registers at startup, but extraction needs a schema-valid CBEFF, and the repo's `src/test/resources/test-cbeff.xml` doesn't pass `mosip-cbeff.xsd` validation.
- **Stubs are static.** The UIN generator always returns `2838501739`, so a second draft without a UIN collides. Every VID resolves to `3649229809`, except `2092493569127145`, which resolves to `7067209349` for `samples/set-2`. PMS returns one partner. Credential requests are accepted but never delivered anywhere. Edit `docker-compose/wiremock/mappings/*.json` to change this.
- **IDE run options (B, C) were not exercised**; Option A (Maven) was.

### Known issues in the service code (pre-existing, not caused by this setup, not fixed here)

- **`PATCH /` with `documents` fails (`IDR-IDC-004`) for an identity that has no stored biometrics.** `IdRepoServiceImpl.updateIdentity` (around line 478) calls `getBiometrics().get(size - 1)` on an empty list.
- **`POST /authtypes/status` returns `IDR-IDC-004` (NullPointerException) when `requestTime` is missing**, instead of a validation error.
- **Unit test `VidDraftHelperTest.activeDraftVidExceptionTest` fails** on the current branch, with or without these changes.

---

## 14. Deviations from the `id-authentication` Reference

| Reference (`id-authentication/local-dev-setup`) | This setup | Why |
|---|---|---|
| ~25 manual edits to the developer's `mosip-config` clone | Unmodified clone + committed overlay served as profile `localdev` | Reproducible, reviewable, no per-developer drift |
| `mosip-config` `develop` | `release-1.3.1` | Must match this code's version (see issue 1) |
| Edits `bootstrap.properties` (profile `default`, label, URI, Keycloak, LoadBalancer) | Separate `bootstrap-localdev.properties`, active only with profile `localdev` | Default/production bootstrap stays untouched |
| Adds `kernel-auth-adapter` to the POM unconditionally | Opt-in `local-dev` Maven profile (auth adapter + `biosdk-client`) | Production gets these jars via `loader.path` at runtime; the packaged artifact must not change |
| Static `init.sql` copy of the schema | Mounts the repo's `db_scripts/mosip_idrepo` and runs it as `deploy.sh` does, plus seeded salts | Local schema can't drift from the real DDL |
| PKCS12 keystore for keymanager (IDA does its own crypto) | Keymanager echo stub | The Identity Service calls keymanager over REST |
| No Keycloak handling needed for IDA's partner-signed APIs | Keycloak token/userinfo stubs + dev JWT (cookie) | All identity endpoints are role-protected |
| No object store | S3Mock container | Identity documents/biometrics require S3 |
| Stubs for masterdata titles/templates, notification, OTP | Stubs for keymanager, ID schema, ID generator, VID service, PMS, credential generator, audit, WebSub | Different service, different dependencies |
| Hard-coded volume path edited in `docker-compose.yml` | `MOSIP_CONFIG_DIR` in `.env` | No edits to tracked files |
| Image `wiremock/wiremock:latest`, healthcheck interval 500 s | `wiremock/wiremock:3.13.1`, interval 10 s | Reproducibility; faster `biosdk-service` start |
| Python IDA sample client | `samples/` (dev token + JSON requests) + curl commands in this document | REST/JSON service; curl is enough |
| Unchanged | Same `biosdk-server:1.3.0` + `mock-sdk 1.3.0-beta.1` + prepare scripts; same config-server settings; `spring.cloud.loadbalancer.enabled=false` | Proven combination from the reference |
