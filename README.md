# IELTS Study Log

Local form for recording IELTS practice. It uses Windows PowerShell/.NET already present on Windows, and your existing Git installation. There is no database, framework, Node/Python/Go runtime, or GitHub token.

The form puts Listening, Reading, Writing, and Speaking in a left sidebar and uses a compact desktop layout designed to fit without page scrolling. Each skill has its own fields. The repository selector lists Git repositories found in `D:\Project\Personal`, `%USERPROFILE%\source\repos`, and `%USERPROFILE%\Documents\GitHub`. Additional scan roots can be set in `IELTSLOG_REPO_ROOTS` using semicolon-separated paths.

> The repository created for this project is public. Any study logs pushed to it will also be public. Do not include private notes or private recording links.

## Start

1. Clone your IELTS journal repository with GitHub Desktop or Git. Make sure `git push` already works from that checkout.
2. In CMD, change to this app folder and run:

   ```cmd
   ieltslog
   ```

   Or double-click `ieltslog.cmd`. It starts the local server and opens `http://127.0.0.1:8765` in your browser. Keep the CMD window open while using the form; press Ctrl+C or close it to stop.
3. Click **Refresh**, select your journal repository from the list, then click **Link repository**. The app remembers it locally.
4. After studying, select the skill, fill in the prepared fields, and submit. The app appends the entry, creates a Git commit, and runs `git push`.

To run `ieltslog` from any CMD folder, add this app folder to your Windows user `PATH` once. Otherwise, run it from this folder.

## Log files

- `logs/listening.md`
- `logs/reading.md`
- `logs/writing.md`
- `logs/speaking.md`

The selected skill controls which file gets the new entry. Study4 and other sources are entered manually; the form does not access Study4.

## How it works

- The server binds only to `127.0.0.1` on port `8765`.
- Local configuration is stored as a small JSON file in `%LOCALAPPDATA%\IELTSStudyLog\config.json`; study data stays as Markdown in your Git repository.
- Git authentication is handled by your existing Git Credential Manager/SSH setup. The app does not ask for or store a GitHub token.
- If push fails, the Markdown and local commit remain in your repository. Resolve the Git issue and run `git push` there.
- The app refuses to submit while unrelated changes are already staged, so its commit will not include them.
- Make sure Git has `user.name` and `user.email` configured; use an email connected to GitHub if you want eligible commits credited on your contribution graph.
