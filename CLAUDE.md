# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

The Maven parent POM is **not** at the repo root — it is at `id-repository/pom.xml`. Run all Maven commands for the services from `id-repository/`. Other top-level directories:

- `api-test/` — separate Maven project: REST Assured + TestNG API test rig (`apitest-idrepo`), run against a deployed environment, not locally.
- `db_scripts/` — Postgres DDL/DML for the three databases: `mosip_idrepo`, `mosip_idmap`, `mosip_credential`. `db_upgrade_scripts/` and `db_release_scripts/` hold version-to-version migrations.
- `helm/`, `deploy/` — Kubernetes charts and install/delete/restart scripts.

## Build and test

Requires JDK 21 and Maven 3.9.x. Dependencies come from MOSIP's `kernel-bom` (version pinned in the parent POM).

```bash
cd id-repository
mvn clean install -Dmaven.javadoc.skip=true -Dgpg.skip=true      # full build + tests
mvn clean install -DskipTests -Dmaven.javadoc.skip=true -Dgpg.skip=true

# Single module (build id-repository-core too, since every service depends on it)
mvn test -pl id-repository-identity-service -am -DfailIfNoTests=false -Dtest=IdRepoServiceTest
mvn test -pl id-repository-vid-service -Dtest=VidServiceImplTest#testMethodName   # needs core already installed
```

- Tests are JUnit 4 (`@RunWith(SpringRunner.class)` mostly, some Mockito/PowerMock). Surefire is 2.22 and the parent POM injects `--add-opens` flags needed by PowerMock/reflection on Java 21 — run tests through Maven, or replicate those flags in the IDE.
- Test config lives in each module's `src/test/resources/application*.properties`.
- JaCoCo excludes `constant`, `config`, `dto`, `entity`, `repository`, `httpfilter` packages from coverage (Sonar runs in CI).
- CI (`.github/workflows/push-trigger.yml`) uses shared `mosip/kattu` workflows: Maven build of `./id-repository`, Docker builds per service, Sonar, and a separate build of `./api-test`.

## Running a service

Services have no `application.properties` in `src/main/resources`; only `bootstrap.properties`, which points at a **Spring Cloud Config server** (`spring.cloud.config.name=application,id-repository`). A running config server with the MOSIP config repo is required. Running also requires `kernel-auth-adapter.jar` on the classpath, and the identity service needs a Biometric SDK jar (or MOSIP mock-sdk).

```bash
java -Dspring.profiles.active=<profile> -Dspring.cloud.config.uri=<config-url> \
     -Dspring.cloud.config.label=<config-label> -jar <jar-name>.jar
```

Each service's port and servlet path are in its `src/main/resources/bootstrap.properties`; Swagger is at `<servlet-path>/swagger-ui/index.html`.

**Identity service without a platform:** `id-repository/id-repository-identity-service/LOCAL_DEV_SETUP.md` runs it locally. Docker Compose provides Postgres, the config server, WireMock stubs for the MOSIP dependencies, the biosdk server and an S3 mock. You then run `mvn -Plocal-dev spring-boot:run`, and open `http://localhost:8082/dev-login` for Swagger. The other services have no local setup yet.

## Architecture

All modules are Spring Boot apps except `id-repository-core`, a shared library. Each service is a separate deployable; they communicate over REST (via `RestHelper` / `RestRequestBuilder` in core, endpoints keyed by `RestServicesConstants`) and WebSub (`IdRepoWebSubHelper`, kernel websub client).

**id-repository-core** holds what crosses service boundaries:
- `spi/` — service interfaces (`IdRepoService`, `VidService`, `IdRepoDraftService`, `AuthtypeStatusService`, `BiometricExtractionService`) implemented in the service modules.
- `security/IdRepoSecurityManager` — UIN hashing/encryption via keymanager, using salts from the `uin_hash_salt` / `uin_encrypt_salt` tables.
- `config/IdRepoDataSourceConfig` — base JPA/Hikari datasource config the service configs extend (pool sizes are `mosip.idrepo.db.pool.*` properties). `ShardDataSourceResolver` (a routing datasource) + `ShardResolver` exist for DB sharding, but sharding is currently commented out.
- `manager/CredentialServiceManager`, `CredentialStatusManager` — trigger credential issuance and track status; `manager/partner/` caches partner lists.

**id-repository-identity-service** (DB `mosip_idrepo`) — owns identity records keyed by UIN; see its own `CLAUDE.md` for API, design and gotchas.

**id-repository-vid-service** (DB `mosip_idmap`) — creates/revokes/regenerates VIDs. Calls the identity service (`IDREPO_IDENTITY_SERVICE`) to resolve UINs and the kernel VID generator, and publishes VID events.

**Credential issuance pipeline:** identity/VID changes → `CredentialServiceManager` → **credential-request-generator** (DB `mosip_credential`; persists requests and a Spring Batch scheduled job in `batch/config` picks them up and reprocesses failures) → **credential-service**, which builds the credential via a `provider/` implementation (`IdAuthProvider`, `QrCodeProvider`, `VerCredProvider`, selected by credential type, see `CredentialType.json`) and delivers it to partners via WebSub.

**id-repository-salt-generator** — Spring Batch job that populates salt tables in the idrepo and idmap databases; run once per environment setup.

Note: the credential feeder has moved to the `mosip-utilities` repository.
