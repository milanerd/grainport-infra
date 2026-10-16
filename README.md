# Deployment Overview

This directory documents the current public deployment shape for the GrainFreak site, GrainPort app, and GrainPort API.

## Current Domain Map

- `grainfreak.com`
  - redirects to `https://www.grainfreak.com`
- `www.grainfreak.com`
  - GrainFreak marketing website
- `test.grainfreak.com`
  - GrainFreak staging website
- `grainport.app`
  - GrainPort web app
- `www.grainport.app`
  - redirects to `https://grainport.app`
- `test.grainport.app`
  - GrainPort staging web app
- `api.grainport.app`
  - GrainPort production API
- `api-staging.grainport.app`
  - GrainPort staging API

The Caddy configuration that matches this model is in [Caddyfile](./Caddyfile).

## Server Layout

Recommended paths on the Hetzner host:

- `/srv/grainport/grainport-api-production/` (branch: `main`)
- `/srv/grainport/grainport-api-staging/` (branch: `dev`)
  - API repo checkouts (Docker Compose per environment)
- `/srv/grainport/grainport-infra/`
  - Infrastructure repo — deploy.sh, Caddyfile, backup script
- `/srv/grainport/grainfreak-website/current`
  - live GrainFreak static export
- `/srv/grainport/grainfreak-website-test/current`
  - staging GrainFreak static export
- `/srv/grainport/grainport-webapp/current`
  - live GrainPort web export
- `/srv/grainport/grainport-webapp-test/current`
  - staging GrainPort web export

## API Deployment

Use [deploy.sh](./deploy.sh) which handles API + web + Caddy from a single command:

```bash
./deploy.sh api staging      # staging API
./deploy.sh api production   # production API
./deploy.sh web staging      # staging web app
./deploy.sh caddy production # Caddy reverse proxy
./deploy.sh all staging      # deploy everything to staging
```

Expected internal bindings:

- staging API: `127.0.0.1:4001`
- production API: `127.0.0.1:4000`

Public access should happen only through Caddy.

## App Environment Layout

### Local / staging app

File:

```text
grainport-app/.env.local
```

Typical values:

- `EXPO_PUBLIC_API_BASE_URL=https://api-staging.grainport.app`
- `EXPO_PUBLIC_SUPABASE_URL=<staging-supabase-url>`
- `EXPO_PUBLIC_SUPABASE_ANON_KEY=<staging-supabase-anon-key>`
- `EXPO_PUBLIC_RC_IOS_API_KEY=<staging-revenuecat-key>`

### Production app

Use production env injection or EAS secrets for:

- `EXPO_PUBLIC_API_BASE_URL=https://api.grainport.app`
- `EXPO_PUBLIC_SUPABASE_URL=<production-supabase-url>`
- `EXPO_PUBLIC_SUPABASE_ANON_KEY=<production-supabase-anon-key>`
- `EXPO_PUBLIC_RC_IOS_API_KEY=<production-revenuecat-key>`

## Reverse Proxy

Deploy the Caddy config via [deploy.sh](./deploy.sh):

```bash
./deploy.sh caddy production
```

This validates before committing and reloads automatically.

## Website Deployment

### GrainFreak website

The GrainFreak website is a static Next.js export from `grainfreak-website`.

Build locally:

```bash
cd grainfreak-website
npm install
npm run build
```

Deploy `grainfreak-website/out/` to:

- production: `/srv/grainport/grainfreak-website/current`
- staging: `/srv/grainport/grainfreak-website-test/current`

Detailed steps are in [DEPLOY.md](/Users/milan/dev/grainport/grainfreak-website/DEPLOY.md).

### GrainPort web app

The GrainPort browser build is exported from `grainport-app`.

Build locally:

```bash
cd grainport-app
npx expo export --platform web
```

Deploy `grainport-app/dist/` to:

- production: `/srv/grainport/grainport-webapp/current`
- staging: `/srv/grainport/grainport-webapp-test/current`

Detailed web-app steps are in [WEB-LAUNCH.md](/Users/milan/dev/grainport/grainport-app/WEB-LAUNCH.md).

## iOS App Release

iOS build, archive, upload, and environment steps are documented in:

- [DEPLOY.md](/Users/milan/dev/grainport/grainport-app/DEPLOY.md)

## External Services That Must Match

Before release, confirm:

- Supabase Site URL and redirect URLs match the public web/app domains
- RevenueCat keys match the target environment
- Stripe keys and webhook secrets match the target environment
- support and pricing links point to `grainfreak.com` and `@grainfreak.com`
- App Store metadata matches the current legal/company naming

## Recommended Rollout Order

1. Deploy staging API.
2. Verify `https://api-staging.grainport.app/status`.
3. Deploy staging GrainFreak website.
4. Verify `https://test.grainfreak.com`.
5. Deploy staging GrainPort web app.
6. Verify `https://test.grainport.app`.
7. Run auth, routing, save-place, export, billing, and password-reset smoke tests.
8. Deploy production API.
9. Verify `https://api.grainport.app/status`.
10. Deploy production GrainFreak website.
11. Verify `https://www.grainfreak.com`.
12. Deploy production GrainPort web app.
13. Verify `https://grainport.app`.
