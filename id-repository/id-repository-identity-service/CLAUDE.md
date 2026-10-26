# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the **Identity Service** module (`id-repository/id-repository-identity-service`). Repo-wide build, CI and module overview are in the root `CLAUDE.md`.

## What this service is

The authoritative store of a person's foundational identity in MOSIP. It stores, updates and retrieves identity records keyed by UIN, and manages UIN status (`ACTIVATED`, `BLOCKED`, `DEACTIVATED`). Main callers are Registration Processor (create/update/drafts), ID Authentication (IDA, via credentials/events) and Resident Services (retrieve, auth-type lock, update counts).

- **Demographics** (identity JSON): encrypted in the `mosip_idrepo` Postgres DB (`uin.uin_data`).
- **Biometrics (CBEFF XML) and documents**: encrypted in the Object Store (S3/MinIO via khazana `ObjectStoreAdapter`). Only metadata and hashes are kept in `uin_biometric` / `uin_document`.

External dependencies, all via `RestHelper` / `RestRequestBuilder` from core, with URLs from `RestServicesConstants` property keys:

| Dependency | Used for |
|---|---|
| Kernel Keymanager | encrypt/decrypt identity data, UIN, handles, object-store files |
| Kernel ID generator | new UIN when a draft is created without one |
| Kernel Syncdata / Masterdata | identity schema for `IDSchemaVersion` (cached in memory, never evicted) |
| VID service | UIN↔VID lookup, listing VIDs on UIN update, draft VID create/activate |
| Credential Request Generator | credential issuance to IDA / partners (driven asynchronously, see below) |
| PMS | list of active online-verification (OLV) partners |
| WebSub | publish identity/auth-type events; subscribe to VID events |
| Audit Manager | `AuditHelper` audit on every controller call |
| Biometric SDK (`kernel-biosdk-provider`) | template extraction on retrieve |

## Build, test, run

Run Maven from `id-repository/` (the parent POM). Every service depends on `id-repository-core`.

```bash
mvn install -pl id-repository-core -DskipTests -Dgpg.skip=true                        # after any core change
mvn test -pl id-repository-identity-service                                           # module tests
mvn test -pl id-repository-identity-service -Dtest=IdRepoServiceTest                  # one class
mvn test -pl id-repository-identity-service -Dtest=IdRepoServiceTest#testAddIdentity  # one method
mvn clean install -pl id-repository-identity-service -am -DskipTests -Dgpg.skip=true -Dmaven.javadoc.skip=true
```

- Tests are JUnit 4. Most use `@WebMvcTest` + `@ActiveProfiles("test")` + `@ContextConfiguration(classes = {TestContext.class, WebApplicationContext.class})`, with collaborators mocked. Config comes from `src/test/resources/application-test.properties` (~200 props). Fixtures are `identity-mapping.json`, `identity-data.json` and `test-cbeff.xml`.
- A new `@Value`/`@Resource` property needs adding to `application-test.properties`, or the test context fails to start.

**Running locally without the platform:** follow `LOCAL_DEV_SETUP.md` (Docker backing services + `mvn -Plocal-dev spring-boot:run`, Spring profile `localdev` — never `local`, which makes the auth adapter reject all tokens). Calls need the dev JWT from `local-dev-setup/samples/dev-token.txt` sent as a cookie `Authorization=<token>`, not a Bearer header. For Swagger UI, open `http://localhost:8082/dev-login` once: a WireMock stub sets that cookie. Ready-made requests are in `local-dev-setup/samples/` and `samples/set-2/`.

**Running against a real environment:** there is no `application.properties`. `bootstrap.properties` points to a Spring Cloud Config server (`spring.cloud.config.name=application,id-repository`) with profile and label. The config repo supplies `application-<profile>.properties` and `id-repository-<profile>.properties`, plus `identity-mapping.json` (`mosip.identity.mapping-file`). The classpath also needs `kernel-auth-adapter.jar` and a biometric SDK jar (or MOSIP mock-sdk).

The MOSIP developer guide (docs.mosip.io → ID Repository → Identity Service developer guide) has local-setup steps:
- run the config server in `native` profile against a local `sandbox-local` copy of `mosip-config`
- set `mosip.idrepo.db.url`/port and `mosip.idrepo.mosip-config-url`
- comment out the `mosip.biometric.sdk.providers.*` and `mosip.kernel.idobjectvalidator.referenceValidator` lines
- start with `-Dspring.profiles.active=default -Dspring.cloud.config.uri=http://localhost:51000/config -Dspring.cloud.config.label=master`

`application-local1.properties` is an example override set (host URLs, DB, S3 keys with blank secrets).

- Port `8090`, context path `/idrepository/v1/identity`.
- Swagger: `http://localhost:8090/idrepository/v1/identity/swagger-ui/index.html?configUrl=/idrepository/v1/identity/v3/api-docs/swagger-config`
- Published API docs: https://mosip.github.io/documentation/ (identity-service).

## REST API

All paths are relative to `/idrepository/v1/identity`. Every endpoint is guarded by `@PreAuthorize("hasAnyRole(@authorizedRoles.getXxx())")`. The role lists are config properties bound to `AuthorizedRolesDto` (prefix `mosip.role.idrepo.identity`). To add an endpoint, add a field there and the matching property in config and in test props.

### `IdRepoController`

| Method & path | Purpose |
|---|---|
| `POST /` | Create identity. The UIN is read from the request using JSONPath `mosip.idrepo.identity.json.path`. Request id must be `mosip.id.create`. |
| `PATCH /` | Update identity, or change status via `request.status`. Request id `mosip.id.update`. |
| `GET /idvid/{id}?type=&idType=&fingerExtractionFormat=&irisExtractionFormat=&faceExtractionFormat=` | Retrieve by UIN / VID / RID (`idType=ID`) / `HANDLE`. `type` is `bio`, `demo`, `metadata` or `all` (comma-combinable); demographics only when omitted. |
| `POST /idvid/` | Same as above, with the id in the body (`IdRequestByIdDTO`), so the UIN is not in the URL. |
| `POST /idvid/v2` | Same, wrapped in `RequestWrapper`. |
| `GET /authtypes/status/individualIdType/{IDType}/individualId/{ID}` and `GET /authtypes/status/{ID}` | Auth-type lock status. |
| `POST /authtypes/status` | Lock/unlock auth types (with optional temporary unlock). |
| `GET /rid/{individualId}?idType=` | Latest RID for a UIN/VID. |
| `POST /idvid-metadata/search` | RID plus created/updated timestamps for UIN/VID/RID (`IndividualIdValidator` binds here). |
| `GET /{individualId}/update-counts?idType=&attribute_list=` | Remaining allowed updates per attribute. |

When `idType` is omitted, `getIdType()` guesses: it tries the UIN validator, then the VID validator, and otherwise treats the id as a RID.

### `IdRepoDraftController` (`/draft`, used by Registration Processor)

| Method & path | Purpose |
|---|---|
| `POST /draft/create/{registrationId}?UIN=` | Start a draft. With `UIN`: copy of the existing identity (update flow). Without: a new UIN is generated (new-registration flow). The parameter name is case-sensitive: `?uin=` is silently ignored and starts a new-registration draft. |
| `PATCH /draft/update/{registrationId}` | Merge identity/documents into the draft. |
| `PUT /draft/extractbiometrics/{registrationId}?*ExtractionFormat=` | Pre-extract and cache templates for the draft. |
| `GET /draft/publish/{registrationId}` | Promote the draft to a real identity (add or update), then delete the draft. |
| `DELETE /draft/discard/{registrationId}` | Drop the draft. |
| `HEAD /draft/{registrationId}` | Draft exists? |
| `GET /draft/{registrationId}?*ExtractionFormat=` | Read the draft, including docs/biometrics. |
| `GET /draft/uin/{UIN}` | Drafts pending for a UIN (RID, created time, attribute names). |

### `VidEventCallbackController`

`POST /callback/vid_credential_status_update` is the WebSub subscriber for VID events, verified by `@PreAuthenticateContentAndVerifyIntent`. Subscription happens at startup in `IdentityWebsubConfig`. It hands off to core `CredentialStatusManager`.

### Request/response shape

`IdRequestDTO` = `RequestWrapper<RequestDTO>`: `id`, `version`, `requesttime`, `request`. The `request` object has:
- `registrationId`, `status`
- `identity` (free-form JSON validated against the ID schema)
- `documents[] {category, value}` (value is URL-safe base64; `category` must match an identity field, e.g. `individualBiometrics` → CBEFF)
- `verifiedAttributes[]`

Responses are `IdResponseDTO`, with `response.identity`, `response.documents` and `response.status`. `verifiedAttributes` is stored inside the identity JSON and split out on read. Errors use `IDR-IDC-0xx` (request/DB) and `IDR-IDS-0xx` (crypto, object store, schema, extraction) from core `IdRepoErrorConstants`.

## Code architecture

```
Controller ──validate (IdRequestValidator via @InitBinder)──► IdRepoProxyServiceImpl ──► IdRepoServiceImpl (@Primary) ──► JPA repos + ObjectStoreHelper
                                                                 │                         ▲
IdRepoDraftController ───────────────────────────────────────► IdRepoDraftServiceImpl ─────┘ (extends IdRepoServiceImpl)
```

- **`IdRepoProxyServiceImpl`** is the façade for the main controller. It does id-type resolution (VID → UIN via VID service; RID via `uin`, then `uin_h`; handle → `handle` table), computes the salted UIN hash, and checks for duplicates (a RID must be unused across `uin`, `uin_draft` and `uin_h`). It also fetches and hash-verifies files, coordinates biometric extraction, builds the response, and publishes `IDENTITY_CREATED` / `IDENTITY_UPDATED` WebSub events. The update event is sent only if the resulting status is active, and event failures are only logged.
- **`IdRepoServiceImpl`** does persistence: add/update identity, documents, history rows, handles, update-count tracking, and queues credential issuance. Its class-level `@Transactional` is **commented out**, so each repository save commits on its own. Object-store uploads ("Phase A") deliberately happen before DB writes ("Phase B") so DB connections are not held during S3 I/O. Keep that ordering.
- **`IdRepoDraftServiceImpl`** is `@Transactional` and reuses the parent's `addIdentity`/`updateIdentity` on publish. Methods that make long REST/S3 calls suspend the transaction with `Propagation.NOT_SUPPORTED` (`extractBiometrics`, `IdRepoServiceHelper.generateUin`, `VidDraftHelper.generateDraftVid`). Use the same pattern for new remote calls inside draft flows.
- **`AuthTypeStatusImpl`** handles auth locks in `uin_auth_lock`:
  - Codes look like `demo`, `bio-FINGER`, `otp-email`.
  - A temporary unlock is stored as locked plus `unlockExpiryDTtimes`.
  - After saving, it publishes `<partnerId>/AUTH_TYPE_STATUS_UPDATE` to every active PMS partner.
  - It keys rows by an **unsalted** `securityManager.hash(uin)`, unlike the salted `uin_hash` used everywhere else.
- **`BiometricExtractionServiceImpl`** runs extraction per modality, `@Async("withSecurityContext")`, through `BioExtractionHelper` (biosdk `BioAPIFactory`). Results are cached in the object store under a derived file name next to the original CBEFF. Concurrent identical requests share one in-flight future, and the overall wait is capped by `mosip.idrepo.bio.extraction.timeout-seconds` (default 30). BIRs marked `others.EXCEPTION=true` are skipped.

### Data protection (do not bypass)

- **Salts:** `IdRepoSecurityManager.getSaltKeyForId(uin)` (a modulo of the id) picks a salt id. The salt itself comes from `uin_hash_salt` (for hashing) or `uin_encrypt_salt` (for encryption).
- **`uin.uin_hash`** = `"<saltId>_<SHA-256(uin+salt)>"`. Lookups always go through this.
- **`uin.uin`** = `"<saltId>_<encrypted uin>"`. The service builds `"<saltId>_<uin>_<encryptSalt>"`, and **`IdRepoEntityInterceptor`** (Hibernate interceptor) encrypts it on save.
- **`uin_data`:** the interceptor encrypts it on save/flush. On load it decrypts and checks `uin_data_hash`, throwing `IDR-IDS-001` on mismatch. So entities in memory hold plaintext, and any new entity implementing `UinInfo`/`HandleInfo` gets this behaviour automatically.
- **Object store:**
  - Path is `<uinHash without saltId>/Biometrics|Demographics/<uuid>.<format>`.
  - Bytes are encrypted with keymanager ref ids (`BIO_DATA_REFID` / `DEMO_DATA_REFID`).
  - Each file's hash is checked on read (`IDR-IDS-002`), except when extraction formats are requested.
  - Reads are capped at `mosip.idrepo.objectstore.max-object-size-bytes` (10 MB).

### Update semantics (`IdRepoServiceImpl.updateIdentity`)

- **Trimming:** string values (and `value` inside language arrays) are trimmed when `mosip.idrepo.update-identity.trim-whitespaces=true`.
- **Merge:** the incoming identity is merged into the stored JSON with `JSONCompare` in LENIENT mode. Missing fields are added, changed fields are overwritten, and language-tagged arrays are merged per `language`. Fields listed in `mosip.idrepo.update-identity.fields-to-replace` are replaced wholesale. Partial updates are therefore normal; callers send only changed attributes.
- **Verified attributes:** `verifiedAttributes` accumulate (set union) across updates.
- **CBEFF:** new BIRs replace existing ones by `type+subtype`, and the others are kept. A new file is written and the metadata row repointed; old files are not deleted.
- **Update limits:**
  - Per-attribute limits come from `attributeUpdateCountLimit` in identity-mapping JSON (`IdentityUpdateTrackerPolicyProvider`, `@RefreshScope`).
  - Counts live in `identity_update_count_tracker` (keyed by uin hash, base64 JSON). Exceeding a limit throws `IDR-IDC-013`.
  - Draft updates compute the diff but don't persist counts.
- **History:** every add/update writes a `uin_h` row, plus `uin_biometric_h` / `uin_document_h` rows for new files.

### Credential issuance (asynchronous, table-driven)

Create/update never calls the credential service inline:
1. `IdRepoServiceImpl.issueCredential` writes or updates rows in `credential_request_status`.
   - Status is `NEW` when the UIN is active, `DELETED` when it is blocked/deactivated.
   - Trigger action is `CREATE` or `UPDATE`.
   - A brand-new UIN first gets a row under a *dummy OLV partner* placeholder.
2. `IdentityScheduleConfig` runs `CredentialStatusManager.triggerEventNotifications()` (core) every `CREDENTIAL_STATUS_JOB_DELAY` ms (default 1000). Each run handles DELETED rows, then expired rows, then NEW rows.
3. `CredentialServiceManager.notifyUinCredential` (core) expands the dummy partner to the real OLV partners from PMS and fetches the UIN's VIDs. For active identities it calls the Credential Request Generator (`CREDENTIAL_REQUEST_SERVICE[_V2]`). For blocked/deactivated ones it sends IDA WebSub events instead. The row then becomes `REQUESTED` or `FAILED`.

Changes to issuance behaviour mostly belong in `id-repository-core/.../manager/`, not in this module.

### Drafts and VIDs

- Draft tables (`uin_draft`, `uin_biometric_draft`, `uin_document_draft`) mirror the live ones.
- `createDraft` refuses a RID already in `uin_h`/`uin_draft`, unless `mosip.idrepo.create-identity.enable-force-merge=true`. With force-merge it resolves the UIN from the RID instead.
- `publishDraft` re-validates the assembled request against the schema.
  - **New identity:** generates a *draft VID* (when a draft VID type is configured), calls `addIdentity`, then activates that VID.
  - **Existing UIN:** calls `updateIdentity`.
  - In both cases it then deletes the draft rows.

### Handles

- Schema fields with `"handle": true` can be listed in the identity's `selectedHandles` field (field ids come from `identity-mapping.json`).
- Each handle value is lowercased and suffixed with a postfix. The postfix comes from `mosip.identity.fieldid.handle-postfix.mapping`, default `@<fieldId>`.
- The handle is salted-hashed and stored encrypted in the `handle` table (core entity). A duplicate fails with `IDR-IDC-014`.
- Retrieval by handle uses `idType=HANDLE`.

### Anonymous profile and channel info

After every add/update/publish, `AnonymousProfileHelper.buildAndsaveProfile()` runs `@Async("anonymousProfileExecutor")`. It writes a de-identified `IdentityIssuanceProfile` (old vs new identity/biometrics) to `anonymous_profile`. `ChannelInfoHelper` (`REQUIRES_NEW`) updates `channel_info` email/phone counts. Failures are only logged.

**Concurrency caveat:** the helper is a singleton `@Component` with mutable instance fields (`regId`, `oldUinData`, `newUinData`, `oldCbeff`, `newCbeff`, `uinHash`) set through fluent setters during the request. Concurrent requests can interleave these values. Keep this in mind before relying on it or extending it.

### Threading (`IdRepoConfig`)

Named `ThreadPoolTaskExecutor`s, each sized by its own properties:

| Pool | Properties | Used by |
|---|---|---|
| `executor` (primary) | `mosip.idrepo.executor.*` | general async |
| `webSubHelperExecutor` | `mosip.idrepo.websub-executor.*` | WebSub publish/receive |
| `credentialStatusManagerJobExecutor` | `mosip.idrepo.cred-status-executor.*` | credential status jobs |
| `anonymousProfileExecutor` | `mosip.idrepo.anon-profile-executor.*` | anonymous profile builds |
| `withSecurityContext` | `mosip.idrepo.extract.template.*` | async work that needs the caller's auth token (bio extraction) |

`monitorThreadQueueLimit()` is a scheduled task that logs pool saturation. Pick the matching pool for new `@Async` work. Use `withSecurityContext` when the async code makes authenticated REST calls.

### Validation (`IdRequestValidator`)

A Spring `Validator` bound to `idRequestDTO` via `@InitBinder`. It checks:
- request `id` and `version`, and RID format
- `status`: must be one of `mosip.idrepo.identity.uin-status` on update
- documents: duplicate categories, and each category must exist in the identity
- the identity object, with kernel `IdObjectValidator` against the schema for its `IDSchemaVersion`. Mandatory attributes come from `mosip.kernel.idobjectvalidator.mandatory-attributes.id-repository.new-registration` or `.update-uin`.

UIN/VID/RID format checks use kernel `kernel-idvalidator-*`.

### Other notes

- `DefaultShardResolver` + core `ShardDataSourceResolver` exist, but sharding is disabled (single `idRepoDataSource`).
- `mosip.idrepo.identity.uin-status.registered` is the "active" status, `ACTIVATED` in test props.

## Database (`mosip_idrepo`)

DDL is in `db_scripts/mosip_idrepo/ddl/`. Upgrades are in `db_upgrade_scripts/`; schema changes need both. Tables:
- live: `uin`, `uin_biometric`, `uin_document`
- history: `uin_h`, `uin_biometric_h`, `uin_document_h`
- drafts: `uin_draft`, `uin_biometric_draft`, `uin_document_draft`
- other: `uin_auth_lock`, `handle`, `credential_request_status`, `identity_update_count_tracker`, `anonymous_profile`, `channel_info`, `uin_hash_salt`, `uin_encrypt_salt`

The salt tables are populated once per environment by the salt-generator job. DDL is never auto-generated (`ddl-auto=none`).
