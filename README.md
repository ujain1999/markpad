# Markpad

A minimal markdown notepad for macOS. Intentionally simple with no AI, no fancy bells and whistles.

![Markpad demo](docs/demo.gif)

Markdown is shown the way Obsidian shows it: the syntax is hidden and the text
renders in place, with the raw markers coming back only on the line the cursor
is on. There is no preview pane and no second copy of your writing — you edit
the formatted text directly, and the file on disk is always exactly the
characters you typed.

Tables are laid out across the full width of the text column, with the columns
aligned as the delimiter row asks. Put the cursor anywhere in one and the whole
table — not just the line you are on — comes back as plain Markdown to edit.

## Keyboard

| | |
| :--- | :--- |
| New window / New tab / Open | `⌘N` `⌘T` `⌘O` |
| Save / Save As | `⌘S` `⇧⌘S` |
| Find / Find & Replace / Next / Previous | `⌘F` `⌥⌘F` `⌘G` `⇧⌘G` |
| Go to Line | `⌘L` |
| Bold / Italic / Strikethrough | `⌘B` `⌘I` `⇧⌘X` |
| Inline code / Link / Code block | `⇧⌘C` `⌘K` `⌥⌘C` |
| Heading 1–6 / Body text | `⌘1`–`⌘6` / `⌘0` |
| Bullet / Numbered / Task / Quote | `⇧⌘8` `⇧⌘7` `⇧⌘9` `⇧⌘.` |
| Zoom in / out / actual size | `⌘+` `⌘−` `⌃⌘0` |
| Hide Markdown syntax / Highlighting | `⌃⌘E` `⌃⌘H` |
| Status bar / Line numbers | `⌃⌘S` `⌃⌘L` |
| Show all tabs / Previous / Next | `⇧⌘\` `⌃⇧⇥` `⌃⇥` |
| Settings / Shortcut reference | `⌘,` `⌘/` |

## Install

Requires macOS 13 or later.

### Download

Get the `.dmg` from [Releases](https://github.com/ujain1999/markpad/releases),
open it, and drag Markpad into Applications.

Markpad is signed ad-hoc rather than notarized, because notarizing requires a
paid Apple Developer account. macOS quarantines anything downloaded from the
internet, so the first launch is refused with a warning that the app cannot be
checked for malicious software. Clear the quarantine flag once:

```sh
xattr -d com.apple.quarantine /Applications/Markpad.app
```

It opens normally from then on. If you would rather not use the terminal: try
to open it, then go to **System Settings ▸ Privacy & Security**, find the
message about Markpad being blocked, and click **Open Anyway**.

### Build from source

Also needs the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/ujain1999/markpad.git
cd markpad
./build.sh
open build/Markpad.app
```

`build.sh` produces a universal `build/Markpad.app` (arm64 + x86_64). Drag it
into `/Applications` to install it properly. Nothing you build yourself is
quarantined, so it just opens.

## Command line

Markpad installs a `markpad` command the first time it runs, so there is
nothing to set up. It goes to the first writable directory on your PATH among
`~/.local/bin`, `~/bin`, `/usr/local/bin` and `/opt/homebrew/bin`; failing
that, to `~/.local/bin`, and the app tells you how to add it. An existing
`markpad` that Markpad did not put there is never touched.

```sh
markpad notes.md       # opens in Markdown mode
markpad todo.txt       # opens as plain text
markpad new-note.md    # creates the file, then opens it
markpad                # a new empty document
```

The extension decides the mode: `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdwn`
and `.mdtext` open as Markdown, and everything else opens as plain text —
including files with no extension at all.

Filename completion needs no setup — both zsh and bash complete filenames for
a command they do not otherwise know.

## License

Markpad is free software under the [GNU General Public License v3.0](LICENSE).
You may use, study, share and modify it; if you distribute a modified version,
it has to carry the same licence and ship its source.
