std = "lua51"
max_line_length = false

-- The KOReader glue layer talks to modules that only exist inside KOReader.
files["plugin/aidict.koplugin/main.lua"] = {
    globals = { "G_reader_settings" },
}

files["spec/"] = {
    std = "+busted",
}

-- The harness stands in for KOReader's whole world, and for the library sync
-- that world includes os.rename and os.remove: the plugin moves a finished
-- download into place with them, and a spec must not let that reach the
-- machine running the suite. They are put back by `koreader.uninstall`.
files["spec/support/koreader.lua"] = {
    std = "+busted",
    ignore = { "122" },
}

exclude_files = { "dist/" }
