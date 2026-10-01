# The README of an archive

An archive can describe itself the way a git repository does: a
`README.md` stored in it is shown when the archive is opened, and a
`README.md` in a folder of the archive is shown when that folder is
opened. It is an ordinary entry, so:

- every format can carry one (.zx, zip, 7z, tar...), and other archivers
  extract it as a normal file;
- it is added and updated like any other file (`zx a`, `zx u`, the app);
- in a .zx archive, the generations keep its earlier versions.

## Which file

In each folder (the top of the archive included), the first of these
names, compared ignoring case:

1. `README.md`
2. `README.markdown`
3. `README.txt`
4. `README`

A `.md` or `.markdown` file is shown as markdown, the others as plain
text. When two names differ only in case, the one that sorts first
(`README.md` before `readme.md`) is used. Only the first 1 MiB is read.

## Markdown

The usual GitHub flavored markdown: headings (`#` and underlined),
paragraphs, emphasis, strong, strikethrough, inline code and fenced or
indented code blocks, block quotes, ordered, bullet and task lists,
tables, horizontal rules, links (inline, reference and `<...>`), bare
`https://` and `www.` links, images, backslash escapes and the common
entities. Headings get GitHub's anchors (`## Getting started` is
`#getting-started`).

Raw HTML is never interpreted: its tags are dropped and their text is
kept, with two exceptions. `<img src="..." alt="..." width="..."
height="...">` is an image (and follows the image rule below), and
`<br>` is a line break.

## Everything shown comes from the archive

This is the one rule of an archive README: **every resource needed to
show it is an entry of the archive**. A README never makes a reader's
program fetch anything.

| In the README | Allowed | Resolves to |
|---|---|---|
| `![demo](img/demo.gif)` | yes | the entry `img/demo.gif`, relative to the README's folder |
| `![logo](/assets/logo.png)` | yes | the entry `assets/logo.png`, from the top of the archive |
| `![x](../shared/x.png)` | yes, while it stays inside | the entry, one folder up |
| `[guide](docs/guide.md)` | yes | the entry; the reader opens it in the archive |
| `[docs](docs/)` | yes | the folder; the reader opens it (and its README) |
| `[usage](#usage)` | yes | the heading "Usage" of the same README |
| `[home](https://example.com)` | yes, as a link | followed only when the reader chooses to |
| `[mail](mailto:me@example.com)` | yes, as a link | the same |
| `![logo](https://example.com/logo.png)` | **no** | not fetched; the description is shown instead |
| `![x](data:image/png;base64,...)` | **no** | not shown |
| `file:`, `javascript:` and any other scheme | **no** | neither shown nor followed |
| `../` above the top of the archive | **no** | neither shown nor followed |

Paths are `/` separated and may be percent encoded (`my%20file.png`); a
`?query` is ignored and a `#fragment` names a heading of the target.
Animated GIFs play. An image may be at most 16 MiB in the app.

The rule lives in one place, `classifyReadmeUrl` in
`lib/src/readme/readme_links.dart`, which the command line, the API and
the app all use.

## Checking a README

`zx readme -check` lists what can not work: images from outside the
archive, blocked schemes, paths that leave the archive or name entries
the archive does not have, and `#anchors` without a heading. Its exit
code is 1 when it found something, so it can guard a release script:

```sh
zx a project.zx ./project/*          # README.md and img/ at the top
zx readme project.zx                 # print the README of the top
zx readme project.zx docs            # the README of the folder docs
zx readme -check -all project.zx     # check every README of the archive
```

```
README.md: image "https://example.com/logo.png": image from outside the archive (not shown)
README.md: link "docs/old.md": not in the archive
docs/README.md: ok
```

## In the app

The app shows the README of the current folder of an archive below its
items, in a panel that folds with its title bar (and can be turned off:
View > "README of the folder", or Settings). A markdown file selected in
the archive is rendered in the preview pane (the button in its title bar
switches to the text). In both:

- images are read from the archive (`ZxArchive.readBytes`); an image
  from anywhere else is shown as its description with a "blocked" mark;
- a link to a folder of the archive opens it, a link to a file selects
  it (and so previews it), a `#heading` scrolls to it;
- a link to another place asks first, showing the full address, and then
  opens the browser or mail program (or copies the address where that is
  not possible, as on Android).

## From Dart

```dart
final a = await ZxArchive.open('project.zx');
final r = await a.readme();               // the top; readme(dir: 'docs')
if (r != null) {
  print(r.item.path);                     // README.md
  for (final b in r.doc.blocks) { ... }   // MdHeading, MdParagraph, ...
  for (final i in r.issues) print(i);     // what can not work
}
```

`readmeIn(dir)` finds the README of a folder without reading it;
`readmeOf(item)` parses any markdown file of the archive. The file is
read in a worker isolate and parsed with `Isolate.run`. The parser
(`parseMarkdown`), the rule (`classifyReadmeUrl`) and the check
(`checkReadme`) are exported for other front ends.
