# Identity Service — Local Development Setup

The full guide is in [`../LOCAL_DEV_SETUP.md`](../LOCAL_DEV_SETUP.md).

Quick start (after the one-time steps in that guide: clone `mosip-config` `release-1.3.1`, build, run `prepare-biosdk-mock-lib`, create `docker-compose/.env`):

```bash
cd docker-compose && docker compose up -d
cd ../.. && mvn -Plocal-dev spring-boot:run
```

Then open <http://localhost:8082/dev-login>. It sets the dev-token cookie and opens Swagger UI. Ready-made requests are in [`samples/`](samples/) and [`samples/set-2/`](samples/set-2/README.md).
