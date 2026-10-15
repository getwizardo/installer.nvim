-- Winso: an ebook reader for Neovim (EPUB, FB2, MOBI, PDF, DOCX, HTML, Markdown, text).
--
-- The module is split by job:
--   config      defaults and the formats list
--   platform    Termux, install hints, system viewer, cache paths
--   text        word wrap, chapter layout, search, book facts
--   library     progress, bookmarks, settings (library.json)
--   loader      runs extract.py and parses its JSON
--   ascii       colored ASCII grids for pictures
--   theme       reading themes
--   images      pictures: system viewer and ASCII view
--   reader      one book per tab, with the status bar
--   reader_keys keys inside a reader tab
--   shelf       home screen: library, folders, bookmarks, settings
--   commands    `:Winso` and `:Kaeru winso` dispatch
--
-- This file re-exports the public functions so callers keep one name: require("kaeru.winso").

local Commands = require("kaeru.winso.commands")
local Config = require("kaeru.winso.config")
local Library = require("kaeru.winso.library")
local Loader = require("kaeru.winso.loader")
local Platform = require("kaeru.winso.platform")
local Reader = require("kaeru.winso.reader")
local Shelf = require("kaeru.winso.shelf")
local Text = require("kaeru.winso.text")

local M = {}

M.formats = Config.formats
M.defaults = Config.defaults

M.is_termux = Platform.is_termux
M.install_hints = Platform.install_hints
M.opener_command = Platform.opener_command
M.open_external = Platform.open_external
M.image_cache_dir = Platform.image_cache_dir

M.wrap = Text.wrap
M.render_chapter = Text.render_chapter
M.search = Text.search
M.info_lines = Text.info_lines

M.library_path = Library.library_path
M.read_library = Library.read_library
M.write_library = Library.write_library
M.recent = Library.recent

M.parse_extract = Loader.parse_extract
M.load = Loader.load

M.show = Reader.show
M.open = Reader.open
M.goto_chapter = Reader.goto_chapter

M.shelf = Shelf.open
M.command = Commands.command

return M
