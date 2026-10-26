-- Seeds the salt tables used to hash and encrypt UINs, VIDs and handles.
--
-- In a real environment the id-repository-salt-generator job fills ids 0..999
-- (mosip.kernel.salt-generator.start-sequence / end-sequence) with random
-- 16-byte salts, base64 encoded. Locally we derive them deterministically so
-- that the same UIN always hashes to the same value across database resets.
--
-- DEV ONLY: never use these salts outside a local environment.

INSERT INTO idrepo.uin_hash_salt (id, salt, cr_by, cr_dtimes)
SELECT i,
       encode(substring(sha256(convert_to('localdev-hash-salt-' || i, 'UTF8')) FROM 1 FOR 16), 'base64'),
       'localdev',
       now() AT TIME ZONE 'UTC'
FROM generate_series(0, 999) AS i
ON CONFLICT (id) DO NOTHING;

INSERT INTO idrepo.uin_encrypt_salt (id, salt, cr_by, cr_dtimes)
SELECT i,
       encode(substring(sha256(convert_to('localdev-encrypt-salt-' || i, 'UTF8')) FROM 1 FOR 16), 'base64'),
       'localdev',
       now() AT TIME ZONE 'UTC'
FROM generate_series(0, 999) AS i
ON CONFLICT (id) DO NOTHING;
