# PR media and narrated walkthroughs

This reference covers reviewer-facing media for a pull request: before/after
screenshots or videos and narrated walkthroughs, their upload, and the report
when media is incomplete.

Create a short video with voice-over and synchronized subtitles when UI, CLI
or backend changes have meaningful behavior to demonstrate. Documentation and
skill changes need a video only when an actual workflow example helps explain
them. A scroll through the diff alone is usually insufficient. Reuse suitable
current recordings and images instead of repeating work.

## Discover capabilities on this machine

Check the OS, graphical or headless session, available tools and their actual
capabilities. Discover recording, speech synthesis, audio-duration inspection,
video assembly, subtitle rendering and attachment support separately. A screen
recorder alone cannot necessarily combine narration or render captions.

Use existing local tools or an already-authorized configured provider. Do not
assume a particular recorder, voice, model, cloud subscription or OS. Examples
to inspect, not mandatory dependencies:

| Host | Capture candidates | Narration candidates |
| --- | --- | --- |
| macOS | `screencapture`, installed recorder | `say`, installed speech engine |
| Linux | Installed recorder; supported X11 or Wayland capture | Installed eSpeak NG or another speech engine |
| Windows | Installed recorder; supported Windows capture | Available Windows speech engine or another installed synthesizer |

FFmpeg can capture and assemble video when its installed build exposes the
needed devices, codecs and filters. X11 capture does not imply Wayland support.
Browser screenshots are not video; an asciinema cast needs playback capture or
a supported renderer to become a video file. In a headless session, use an
available headless recorder or renderer without assuming a desktop exists.
Consult current help or primary documentation for the chosen tools:
[FFmpeg devices](https://www.ffmpeg.org/ffmpeg-devices.html),
[Wayland ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html),
[Windows speech output](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.setoutputtowavefile),
[eSpeak NG](https://github.com/espeak-ng/espeak-ng/blob/master/docs/guide.md).

Record the host and capture backend actually exercised. [Wine](https://www.winehq.org/about)
can help check whether a Windows media tool runs on the current host, including
encoding or caption assembly from existing inputs. That result establishes
compatibility under Wine, not native Windows capture or speech support. Verify
[Windows capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)
in an actual Windows session with a supported graphics device; a Windows VM can
cover its virtual display, while physical capture devices need their own check.
Wayland capture needs a Wayland session and its capture backend or portal.

## Produce and verify the walkthrough

- Choose a representative, already-validated scenario showing the trigger,
  action and changed result. Use an authorized demonstration environment with
  safe example data. Capture the relevant application or region, excluding
  unrelated windows, notifications and credentials.
- Write brief narration segments explaining the demonstrated behavior. Use a
  suitable installed voice by default. Generate captions from the same script
  and time them to the measured audio and demonstrated actions; transcription
  is unnecessary for a scripted voice-over.
- Assemble the actual recording, narration and readable subtitles. Prefer
  subtitles rendered into the video for consistent playback; optional SRT or
  WebVTT files can accompany it. Rely on selectable tracks only when the target
  player supports them. Verify narration matches what the viewer sees. Do not
  present staged or synthetic examples as execution evidence or edited playback
  timing as a performance measurement.
- Review the finished playback for legible text, intelligible audio, accurate
  captions, synchronization and the claimed result. Check the actual exported
  file; an export command succeeding does not establish playback quality.
- Upload it as described below. A locally created file is not an uploaded,
  reviewer-accessible walkthrough.

## Upload media

Put media into the body in the same command that writes the body, so that,
when every upload succeeds, the PR never exists without it. A first body
without its media shows reviewers an incomplete description, and a repository
check that validates the body when the PR is opened or edited fails that first
run.

- Reference each file in the body as an inline image, `![alt text](<path>)`.
  A video takes the same form. When the repository's template or its body
  check names a field for the media, such as `- Evidence link or path:`, put
  the reference on that field's line, image or video: a check that reads only
  that line finds the field empty when the video sits elsewhere. A video alone
  in a paragraph, with a blank line before and after it, renders as a player;
  beside a named field it is an optional extra, never the only reference. In
  a table cell, beside other text or on a field's line, a video becomes a link
  instead. Give alt text in the body: gh takes
  `--attach '<image>#<alt text>'` for an image but refuses alt text on a
  video. A bare path is not
  a reference: gh leaves it in the body as text and appends the upload at the
  end. Pass `--attach <path>`
  for each file in the command that writes that body:
  `gh pr create --draft --title TITLE --body-file FILE --attach PATH` opens a
  PR, and `gh pr edit N --body-file FILE --attach PATH` rewrites an open PR's
  body. gh 2.99 and newer uploads each file and replaces every reference to it
  with the URL GitHub returns for the upload; a file the body does not
  reference is appended at the end. gh cannot attach on GitHub Enterprise
  Server or without write access to the repository; report that as an upload
  gap, as below.
- Run the command from the repository root and write each path the same in
  the reference and in `--attach`: relative to the repository root, or a
  plain `/tmp/...` path. From gh 2.103 a relative reference is looked up in
  the body file's folder before the working directory, and the
  [publication guard](../../git-workflow/SKILL.md#publication-guard) rewrites
  an absolute path under the home directory or a per-session temporary
  folder, which then no longer names the file. Keep the files where git
  ignores them or outside the checkout.
- Never open the PR first and add its media with a second write, such as
  `gh pr edit --attach` or pasting the uploaded URLs into the body. A command
  that cannot attach never writes a PR's first body: `gh stack submit --auto`
  and `gh stack link` open a PR for a branch without one with the template
  unfilled, so the
  [stack reference](../../git-workflow/references/github-stacks.md#open-a-layers-pull-request)
  opens each layer with `gh pr create` first.
- Read the body back after the write: each reference must point at its
  uploaded URL and no local path may remain. Verify each asset in the actual
  PR. gh stops uploading at the first failure. When some files uploaded, it
  still creates or updates the PR with their URLs and the remaining local
  paths, prints its URL and exits non-zero, so a body check can fail on that
  write; when none uploaded, it creates no PR and writes no body. Read GitHub
  before acting again and never create a second PR. Once the cause is fixed,
  write the complete body again with `gh pr edit N --body-file FILE` and
  every `--attach`. When GitHub shows no PR on that head and the command has
  stopped, run the creation again instead.

Never commit evidence media to the repository.

## Report incomplete requirements without blocking the PR

If capture, voice-over, subtitles, assembly, playback verification or upload
cannot be completed, continue the otherwise-authorized PR workflow. Existing
review, behavior and CI requirements remain in force; a media tooling gap alone
does not keep a PR draft.

In the final user handoff, name each incomplete requirement, the observed
reason and the concrete remedy for this OS, such as a supported tool to install,
a permission to enable or an upload capability to configure. Verify suggested
setup instructions against current tool documentation. Include local artifact
paths and completed stages so the user can resume without repeating work.
Identify missing media briefly in the PR's Visual walkthrough section where a
comparison or walkthrough was expected. Do not silently substitute a silent clip for a narrated, subtitled
video or describe incomplete media as finished. Avoid repeated failed setup
attempts; unsupported tooling is a reported gap, not a new implementation task.
