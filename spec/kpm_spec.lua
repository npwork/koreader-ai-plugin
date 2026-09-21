local Kpm = require("aidict.kpm")

describe("kpm", function()
    describe("finding the binary", function()
        it("takes the platform this device actually carries", function()
            local only_hf = function(path) return path:find("kindlehf", 1, true) ~= nil end
            assert.are.equal("/var/local/kmc/kindlehf/bin/kpm", Kpm.find(only_hf))

            local only_pw2 = function(path) return path:find("kindlepw2", 1, true) ~= nil end
            assert.are.equal("/var/local/kmc/kindlepw2/bin/kpm", Kpm.find(only_pw2))
        end)

        it("finds nothing on a device without KPM", function()
            assert.is_nil(Kpm.find(function() return false end))
        end)
    end)

    describe("the command", function()
        it("installs one package, unattended, with the library beside it", function()
            local command = Kpm.command("/var/local/kmc/kindlehf/bin/kpm", "koreader-aidict")

            assert.is_truthy(command:find("LD_LIBRARY_PATH='/var/local/kmc/kindlehf/lib'", 1, true))
            assert.is_truthy(command:find("-y install 'koreader-aidict'", 1, true))
            -- KPM's failures are on stderr, and that is the half worth reading.
            assert.is_truthy(command:find("2>&1", 1, true))
        end)

        it("never runs upgrade, which would touch every other package", function()
            local command = Kpm.command("/var/local/kmc/kindlehf/bin/kpm", "koreader-aidict")
            assert.is_nil(command:find(" upgrade", 1, true))
        end)
    end)

    describe("reading KPM back", function()
        it("believes its own report of success, typo and all", function()
            local ok, message = Kpm.interpret("Downloading...\nInstalled 1 package(s) succesfully.", true)
            assert.is_true(ok)
            assert.are.equal("Installed 1 package(s) succesfully.", message)

            -- The typo is upstream's; a release that fixes it must not break this.
            assert.is_true(Kpm.interpret("Installed 1 package(s) successfully.", true))
        end)

        it("quotes the failure rather than a status code", function()
            local ok, message = Kpm.interpret(
                "Resolving...\nFailed to install packages (3: network error)\n", true)
            assert.is_false(ok)
            assert.are.equal("Failed to install packages (3: network error)", message)
        end)

        it("does not call silence a success", function()
            local ok, message = Kpm.interpret("", true)
            assert.is_false(ok)
            assert.is_truthy(message)
        end)

        it("takes a bad exit status as the tiebreaker it is", function()
            local ok, message = Kpm.interpret("could not open the database", false)
            assert.is_false(ok)
            assert.are.equal("could not open the database", message)
        end)
    end)
end)
