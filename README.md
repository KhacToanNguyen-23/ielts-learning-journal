# IELTS Study Log

> **One IELTS session. One Markdown log. One Git commit.**  
> Build your English skills and your developer contribution habit at the same time.

IELTS Study Log is a lightweight local app for developers who want to keep a consistent record of IELTS practice. After each session, choose a skill, fill in a short form, and submit. The app saves the session as a dated Markdown entry in your own repository, then commits and pushes it with Git.

Your practice becomes visible, reviewable, and easy to keep up with: every focused session adds another small step to your IELTS progress and your GitHub activity.

## Skills

- **Listening** — section, score, question types, and mistakes to review
- **Reading** — passage, score, question types, and mistakes to review
- **Writing** — task type, word count, self-assessed band, prompt, and feedback
- **Speaking** — part, topic, recording link, and self-assessment

The Activity Overview summarizes study sessions, time, active days, and time by skill. History lets you search and filter past sessions, sort by date, and browse them page by page.

## Start on Windows

1. Clone this repository, or another repository where you want to keep your study logs. Make sure Git can push to it.
2. Open Command Prompt in the app folder and run:

   ```cmd
   ieltslog
   ```

   You can also double-click `ieltslog.cmd`. The app opens `http://127.0.0.1:8765` in your browser. Keep the Command Prompt window open while studying; press **Ctrl+C** or close it to stop the local server.
3. Select your cloned log repository from the repository list and click **Link repository**.
4. After an IELTS practice session, choose a skill in the sidebar, complete its form, and click **Submit log**.

To run `ieltslog` from any Command Prompt folder, add the app folder to your Windows user `PATH`.

## Your study log

Each skill has its own folder. Sessions are appended to a daily Markdown file:

```text
logs/
├── listening/YYYY-MM-DD.md
├── reading/YYYY-MM-DD.md
├── writing/YYYY-MM-DD.md
└── speaking/YYYY-MM-DD.md
```

The app uses the session date for the filename, so multiple sessions on the same day stay together. You can read these files in any text editor or browse them on GitHub.

## How commits count

Every successful submission creates a Git commit and pushes it to the linked repository. That gives your study habit a developer-friendly contribution trail. GitHub decides which commits appear on your contribution graph; use a commit email connected to your GitHub account, and make sure the repository and branch meet GitHub's contribution requirements.

**Keep it honest and sustainable:** log real practice sessions, even if they are short. A steady record matters more than a perfect streak.

> This repository is public. Any logs pushed here are public too. Avoid private notes, personal information, or private recording links. You can link a different private repository for your personal logs.

## Lightweight by design

- Runs locally on Windows using PowerShell and .NET.
- Uses your existing Git installation and Git credentials.
- No database, cloud service, extra runtime, or GitHub token.
- Keeps study records as ordinary Markdown files.
- Stores the linked repository setting locally in `%LOCALAPPDATA%\IELTSStudyLog\config.json`.
- Binds only to `127.0.0.1` on port `8765`.

If a push fails, your Markdown log and local commit remain in the repository. Fix the Git issue, then push from that repository. The app also requires Git `user.name` and `user.email` to be configured.