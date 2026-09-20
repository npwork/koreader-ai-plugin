std = "lua51"
max_line_length = false

-- The KOReader glue layer talks to modules that only exist inside KOReader.
files["plugin/aidict.koplugin/main.lua"] = {
    globals = { "G_reader_settings" },
}

files["spec/"] = {
    std = "+busted",
}

exclude_files = { "dist/" }
