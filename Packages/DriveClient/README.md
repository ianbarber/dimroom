# DriveClient

Google Drive REST v3 client with OAuth 2.0 PKCE authentication. Handles resumable uploads, file metadata operations, and change polling. No vendor SDK — pure URLSession against the Drive API.

## Configuration

No credentials are baked into the binary. `DriveClient` resolves a Google OAuth client ID at runtime via `OAuthConfig.load()`:

1. Environment variable `DIMROOM_GOOGLE_CLIENT_ID` (optionally `DIMROOM_GOOGLE_CLIENT_SECRET`).
2. Config file at `~/Library/Application Support/dimroom/oauth.json` with the shape `{ "client_id": "…", "client_secret": "…" }`.

If neither source provides a client ID, `DriveClient.authenticate()` throws `DriveClientError.clientIDNotConfigured`.

Refresh tokens issued by Google are stored in the macOS Keychain under service `com.dimroom.DriveClient`, account `google.refresh_token`.
