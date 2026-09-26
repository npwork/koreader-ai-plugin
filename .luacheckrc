std = "lua51"
max_line_length = false

-- KOReader's own global, which only exists inside KOReader.
files["plugin/aidict.koplugin/main.lua"] = {
    globals = { "G_reader_settings" },
}

files["spec/"] = {
    std = "+busted",
}

-- The harness swaps os.rename and os.remove so a spec cannot reach the machine running the suite.
files["spec/support/koreader.lua"] = {
    std = "+busted",
    ignore = { "122" },
}

exclude_files = { "dist/" }
