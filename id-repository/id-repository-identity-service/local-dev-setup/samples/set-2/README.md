# Test data set 2

Run in order on an empty database (after `docker compose down -v` and `up -d`). Each file works once: its RID, and on creates its UIN, is used up afterwards.

RIDs use machine `10002`, so they never collide with the RIDs in `../add-identity.json` and the guide (machine `10001`).

| # | Swagger endpoint | Path / query values | Body | Expected |
|---|---|---|---|---|
| 1 | `POST /` | | `01-create-identity.json` | `ACTIVATED`: Priya, UIN `7067209349`, with a document |
| 2 | `POST /` | | `02-create-identity-2.json` | `ACTIVATED`: Rahul, UIN `9512837641` |
| — | `GET /idvid/{id}` | `id` = `2092493569127145`, `idType` = `VID`, `type` = `all` | | Priya (a dedicated WireMock stub maps this VID to `7067209349`; every other VID maps to the guide's `3649229809`) |
| 3 | `PATCH /` | | `03-update-identity.json` | `ACTIVATED`; phone `9845099999`, email `priya.new@example.com` |
| 4 | `POST /authtypes/status` | | `04-authtype-lock.json` | `Success`; `GET /authtypes/status/7067209349` shows `bio-FINGER` and `demo` locked |
| 5 | `POST /idvid-metadata/search` | | `05-metadata-search.json` | `rid` = `10001100020000320261023101000` (the update's RID) |
| 6a | `POST /draft/create/{registrationId}` | `registrationId` = `10001100020000420261023102000`, **`UIN`** = `7067209349` | | `DRAFTED` |
| 6b | `PATCH /draft/update/{registrationId}` | same RID | `06-draft-update.json` | `DRAFTED` |
| 6c | `GET /draft/publish/{registrationId}` | same RID | | `ACTIVATED`; Priya's `addressLine1` is `88 New Colony Road` |
| 7a | `POST /draft/create/{registrationId}` | `registrationId` = `10001100020000520261023103000`, `UIN` **empty** | | `DRAFTED`; new UIN `2838501739` from the ID-generator stub |
| 7b | `PATCH /draft/update/{registrationId}` | same RID | `07-draft-new-registration.json` | `DRAFTED` |
| 7c | `GET /draft/publish/{registrationId}` | same RID | | `ACTIVATED`, `metadata.vid` = `5712817694382350`; Anita, UIN `2838501739` |
| 8 | `PATCH /` | | `08-block-identity.json` | `BLOCKED`; Rahul now reads as `BLOCKED` |

Verified end to end on 2026-10-23, including the dedicated VID stub.

Spare RIDs for your own requests: `10001100020000720261023105000`, `...00008...`, `...00009...` (change the 5-digit sequence).
Spare UINs: `8930136945`, `8759851794`, `4951985461`, `4819801421`, `8395306182`, `6417687315`, `7067904160`, `2734014695`.
