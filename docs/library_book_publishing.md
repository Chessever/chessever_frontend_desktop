# Publishing a folder as a collection

An owned cloud folder or database can be submitted as a collection. Nested
games are included by the server. Library items stay private by default; link
sharing is a separate capability and never publishes anything.

Open **Publish / edit collection...** from a folder's context menu, or use the
upload icon in the folder preview or database workspace header.

Nothing here makes a collection public. Every submission is a private draft
until a ChessEver superadmin approves it from the account page on the website.

## The road a collection takes

| Stage | What the dialog shows | What can be done |
| --- | --- | --- |
| Private draft | "Publish collection" and a checklist of what a submission still needs | Save draft, Submit for approval |
| In review | When it was submitted; it stays private | Withdraw from review, Submit changes, Submit with latest games |
| Changes requested | The note staff sent back | Save draft, Resubmit for approval |
| Live in Collections | A warning that a change takes it out of Collections until it is approved again | Unpublish, Submit changes, Submit with latest games |
| Taken down | That ChessEver took it down | Nothing; ask ChessEver |

The stage is derived, never stored: the publication `status` plus, for a draft,
the server's `review` object (`LibraryBookPublication.stage`). A server that
predates reviews sends no `review`; a draft then always reads as a private
draft, as before.

- **Save draft** saves the details privately.
- **Submit for approval** sends the details and the folder's current games to
  ChessEver. It needs a title, an author credit and a description; the
  checklist beside the preview says what is missing and takes the cursor there.
- **Submit changes** resubmits the details only; **Submit with latest games**
  also replaces the games with the folder's current contents.
- **Withdraw from review** takes a waiting draft back out of the queue. It was
  never public, so nothing else changes.
- **Unpublish** asks first, removes it from Collections, and keeps the private
  folder and the saved details.

Withdrawing and unpublishing keep whatever is typed and not yet saved. A
snapshot holds up to 1,000 games and 10 MB of PGN.

## The editor

Title, Subtitle, Author, Year, Description and Cover, in the order they read on
the collection page, with the phone app's limits and input tidying. The author
is credited to **Me** (pictured by the account's profile photo) or **Someone
else** (existing ChessEver authors are suggested so one person keeps one
spelling, and they may have their own photo). The last author saved under "Me"
pre-fills a fresh collection; crediting someone else clears a name that was
only pre-filled. Unsubmitted edits are kept per folder on this device and
offered back on the next visit.

The preview shows the collection exactly as readers see it: the Collections
list row (cover in the 5:4 frame, title, credit, game count) and the top of its
page. Focusing a field turns the preview to where that field shows and lights
its spot.

## Who approves

Only a superadmin, on the server. The app has no approval call, and the proxy
it talks through allowlists no route that can publish
(`supabase/functions/gamebase-proxy/allowed_routes_test.ts`).

## Transport

Requests carry the member's own session and never an upstream key.

- **Production accounts** go through the `gamebase-proxy` edge function, like
  every other gamebase call the desktop app makes. The function injects the
  server key and, for these member routes only, forwards the member's bearer so
  the server can tell whose folder it is.
- **Test accounts** go through an explicitly configured test proxy,
  `LIBRARY_BOOK_PUBLISHING_BASE`. It must use HTTPS (HTTP only for localhost,
  127.0.0.1 or ::1), carry no credentials, query or fragment, and may never
  point at production ChessEver hosts or another Supabase project.

The two never mix, redirects are never followed, and a production token is only
ever sent to the project's own functions host or a chessever.com host. A
`GAMEBASE_PROXY_BASE` on any other host is passed over for the project's own
function rather than refused, so folder deletion never depends on where the
read proxy lives.

The client appends `/api/library/folders/{folderId}/book` (and `/book/cover`,
`/book/author-photo`), plus `/api/library/authors` for suggestions. A response
contains `{status: "success", data: {folderId, status, book}}`; `book.review`
is `{state, submittedAt, note, decidedAt}`.

### Rollout order

The edge function must be deployed with the library routes before publishing
works for production accounts:

```bash
supabase functions deploy gamebase-proxy --use-api
```

Until then the function answers `route_not_allowed` (or `method_not_allowed`);
the dialog says "Book publishing is not available here yet." and deleting a
folder keeps working exactly as it did before publishing existed here.

## Deleting a published folder

Cloud deletion first withdraws every public collection in the folder subtree
with `DELETE ?includeDescendants=true`. If that request fails, the source folder
is kept so the author can retry without orphaning a public collection. Starting
the withdrawal also fences the subtree from further publication, including
concurrent saves; retry **Delete** to finish. Subscribed books, Likes and
permanent system items can never be published and are deleted without asking.
An invalid-but-present test configuration blocks deletion rather than skipping
the withdrawal. The withdrawal is given a minute; if the server does not answer
the folder is kept and the reason is shown.

## Device checks for the reviewer

1. Open an owned nested folder's context menu and its header upload action.
   Both open the same editor.
2. Save a draft; the folder stays absent from Collections. Reopen it: the
   details persist and the stage reads Private draft.
3. Submit it. The dialog turns to "Collection in review" and the collection is
   still absent from Collections. Withdraw it, then submit again.
4. As a superadmin on the website account page, send it back with a note.
   Reopen the dialog: the note is shown, and Resubmit for approval is offered.
5. Approve it on the website. The dialog reads "Edit collection", live.
6. Disconnect while saving and retry after reconnecting. Input remains, the
   controls prevent double submission, and errors never imply success.
7. Unpublish: it leaves Collections while its source and details remain. Check
   Tab, Escape, and global Cmd/Ctrl+Shift+F.

Runtime validation is left to the user, per repository policy. Automated checks
use static analysis and mocked transport and widget tests only. Form tests
disable semantics because forui 0.16 has a known debug-only input semantics
assertion; screen-reader behaviour still needs a device check.
