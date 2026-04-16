# Bookmarks plugin

A plugin for [**Xournal++**](https://github.com/xournalpp/xournalpp) to add bookmarks and export PDF files with embedded chapters.

The interface is managed using `yad`.

## Features
- **Nested bookmarks** (e.g. `Unit 1/Introduction`)
- **PDF Export**: export your file as PDF + your bookmarks as PDF chapters
- **Import/Export**: move your bookmark structure (JSON format) between different `.xopp` files.

## Dependencies
- [yad](https://github.com/v1cont/yad)
- [pdftk](https://www.pdflabs.com/tools/pdftk-the-pdf-toolkit/) (required only for PDF export)

## Installation
1. Copy `bookmarks-plugin` folder to your Xournal++ plugins folder: `~/.config/xournalpp/plugins/`
2. Restart Xournal++
3. Enable the plugin from `Plugin > Plugin Manager`