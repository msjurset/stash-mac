# Triage Workflow: Read & Watch Later

Stash uses a specific tagging workflow to help you triage new content without cluttering your permanent library. This is driven by two special tags: `read-later` and `watch-later`.

## The Inbox Queue

In the Stash Mac app, the **Inbox** contains a section at the top titled **"To read & watch"**. This is a live, prioritized view of every item in your stash that carries either the `read-later` or `watch-later` tag.

This section acts as your "active" list — things you have stashed recently but haven't finished consuming yet.

## How Items Enter the Queue

There are three ways an item gets added to your triage queue:

1.  **Manual Tagging**: Add the `read-later` or `watch-later` tag to any item via the Mac/Android edit sheets or the CLI:
    ```bash
    stash edit <id> --add-tag read-later
    ```
2.  **Stashing from Feeds**: When browsing RSS/Atom feeds in the Inbox, hitting **"S"** on an item automatically stashes it and applies the `read-later` tag.
3.  **Automatic Rules**: You can configure rules to auto-apply these tags based on domain or content type (e.g., auto-tagging all YouTube links as `watch-later`).

## The "Mark Done" Workflow

Once you have finished reading an article or watching a video, you can remove it from your Inbox queue while keeping it in your permanent library:

*   **In the Mac Inbox**: Select the item and press **"S"** (or click the checkmark). This removes the triage tag and moves the item out of the Inbox.
*   **Manual**: Simply remove the `read-later`/`watch-later` tag in any edit view.

## Priority in Digests

The `stash digest` command prioritizes items with these tags when generating your daily or weekly summaries, ensuring you don't lose track of the things you've explicitly flagged for later consumption.
