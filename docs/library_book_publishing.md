# Library books on desktop

An owned cloud folder or database can become a public book. Nested games are
included by the server. Library items remain private by default; existing link
sharing is a separate capability and does not publish a catalog book.

Open **Publish / edit book...** from a folder's context menu, or use the upload
icon in the folder preview or database workspace header. The editor supports
title, subtitle, author, about, foreword, publisher, publication year, and cover
image URL. A publication snapshot can contain up to 1,000 games and 10 MB of
PGN. Larger sources must be split into smaller folders.

- **Save draft** saves private metadata without publishing.
- **Publish book** explicitly creates a public catalog entry and its initial
  game snapshot.
- **Save details** updates the metadata of an existing public book.
- **Update games** replaces the public snapshot with the latest recursive
  contents of the source folder. Ordinary private edits are not auto-published.
- **Unpublish** asks for confirmation, removes public availability, and keeps
  the private source and stored metadata.

Subscribed books, Likes, and permanent system library items cannot be published.
The server additionally verifies authenticated ownership on every operation.
When publishing is configured, cloud deletion first withdraws all public books
in the folder subtree with `DELETE ?includeDescendants=true`. If that request
fails, the source folder is kept so the author can retry without orphaning a
public book. With publishing unconfigured, ordinary folder deletion is unchanged.

## Environment and API dependency

Publishing is disabled unless `LIBRARY_BOOK_PUBLISHING_BASE` is explicitly set.
For this work, configure only the verified **test** authenticated proxy. This
setting has no fallback to the existing catalog endpoint. No upstream API key
belongs in this app or this setting; the proxy must add its server-side key and
forward the signed-in user's bearer token.

The companion Gamebase change must be installed in the test environment before
this feature can be used. This PR does not deploy or configure any service.
The proxy must allow these authenticated operations:

```text
GET    /api/library/folders/{folderId}/book
PUT    /api/library/folders/{folderId}/book
DELETE /api/library/folders/{folderId}/book
```

A response contains `{status: "success", data: {folderId, status, book}}`.
Publication status is `unpublished`, `draft`, `published`, or `archived`; `book`
is null before metadata exists. PUT sends the editable metadata. Omitting
`publish` saves only details, `publish: true` explicitly publishes, and
`refreshGames: true` explicitly replaces the snapshot. Optional empty fields
are sent as null so clearing a field is preserved. DELETE unpublishes.

Requests use the current signed-in session and the configured public Supabase
anon key for the proxy gateway. Configuration/sign-in errors make no network
request. Concurrent publication (409) remains retryable. Failed requests keep
the user's form input and never show a success state.

## Device checks for the reviewer

1. On the test environment, open an owned nested folder's context menu and its
   header upload action. Confirm both open the same metadata editor.
2. Save a draft; confirm the folder stays absent from Collections. Reopen it
   and verify the metadata persists.
3. Publish with nested games, then confirm the public book and About metadata
   in Collections. Confirm subscribed/system folders have no publish action.
4. Edit a private source game; confirm the public snapshot changes only after
   Update games. Confirm a metadata-only save does not reimport games.
5. Disconnect while saving and retry after reconnecting. Confirm input remains,
   controls prevent double submission, and errors do not imply success.
6. Unpublish and confirm the book leaves public Collections while its source
   and metadata remain. Check Tab, Escape, and global Cmd/Ctrl+Shift+F behavior.

Runtime validation is left to the user, per repository policy. Automated checks
use static analysis and mocked transport/widget tests only. As with the existing
rename-dialog tests, form behavior tests disable semantics because forui 0.16
has a known debug-only input semantics assertion; screen-reader behavior still
needs a device check.
