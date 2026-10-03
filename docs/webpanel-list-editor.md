# WebPanel list editor

The shared list editor is used for exclusions, extra domains, and other text-backed domain lists. It provides filtering, selection, bulk replacement, deletion, import, and a page-session undo action. Validation and conflicts keep the draft available for correction. Bulk edits preserve comments and entries that were not selected; the clear action removes domain entries while retaining comments.

## Save contract

The API returns each editable document with its current text and SHA-256 revision. Save requests include the revision the editor read. The server validates and normalizes the complete document, rejects invalid input as a whole, checks that the revision is still current, then atomically replaces the file under the list lock. A stale revision returns HTTP 409. The editor does not restart the filtering service after saving.

The shared lock coordinates WebPanel mutations. External writers that bypass that lock can still race a save. The undo action is revision-guarded and cannot overwrite a later change made through the same API.

Implementation is in `webpanel/www/core/domain-list-editor.js`, `webpanel/cgi/api.sh`, and the list mutation helpers in `webpanel/cgi/actions.sh`.
