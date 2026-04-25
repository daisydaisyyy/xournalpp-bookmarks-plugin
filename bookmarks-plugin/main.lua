utf8_to_html = require("utf8_to_html")

DEFAULT_EXPORT_PATH = "/tmp/temp"
BOOKMARK_PREFIX = "Bookmark::"
FOLDER_ID_PREFIX = "FOLDER_"

-- YAD button exit codes
YAD_OK = 0
YAD_CLOSE = 1
YAD_EDIT = 2
YAD_DELETE = 3
YAD_RENAME = 3 -- same slot, different dialog

sep = nil -- path separator, set in initUi()

-- utility
function bash_escape(str)
    if not str then
        return "''"
    end
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

function json_escape(str)
    if not str then
        return '""'
    end
    return '"' .. str:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

function show_dialog(msg)
    local cmd = 'yad --info --title="Bookmarks plugin says" --text=' .. bash_escape(msg) .. ' --button="OK:0"'
    run_yad(cmd)
end

function exec_ok(cmd)
    local result = os.execute(cmd)
    -- Lua 5.1: returns numeric exit code (0 = success)
    -- Lua 5.2+: returns true on success, nil/false otherwise
    if type(result) == "number" then
        return result == 0
    end
    return result == true
end

--- run a yad command, capture stdout and exit code
function run_yad(cmd)
    local tmp = os.tmpname()
    os.execute(cmd .. ' > ' .. tmp .. ' 2>/dev/null; echo "EXIT:"$? >> ' .. tmp)
    local f = io.open(tmp, "r")
    if not f then
        return nil, 1
    end

    local lines, code = {}, 1
    for line in f:lines() do
        if line:find("^EXIT:") then
            code = tonumber(line:match("%d+"))
        else
            table.insert(lines, line)
        end
    end
    f:close()
    os.remove(tmp)

    if #lines == 0 then
        return nil, code
    end
    -- strip a single trailing newline that yad normally appends
    local out = table.concat(lines, "\n")
    return out ~= "" and out or nil, code
end

-- bookmarks name helpers

function parse_bookmark_name(raw_name)
    return raw_name:sub(#BOOKMARK_PREFIX + 1)
end

function make_layer_name(display_name)
    return BOOKMARK_PREFIX .. display_name
end

-- get bookmark
function get_bookmarks()
    local structure = app.getDocumentStructure()
    local bookmarks = {}

    for page = 1, #structure.pages do
        for layerID, layer in pairs(structure.pages[page].layers) do
            if layer.name:sub(1, #BOOKMARK_PREFIX) == BOOKMARK_PREFIX then
                table.insert(bookmarks, {
                    page = page,
                    layerID = layerID,
                    display_name = parse_bookmark_name(layer.name)
                })
            end
        end
    end

    table.sort(bookmarks, function(a, b)
        if a.page == b.page then
            return a.display_name < b.display_name
        end
        return a.page < b.page
    end)

    return bookmarks
end

--- create a new layer with a custom name on the current page not showing any dialog
function _create_bookmark_layer(name)
    local structure = app.getDocumentStructure()
    local activeLayer = structure.pages[structure.currentPage].currentLayer

    app.layerAction("ACTION_NEW_LAYER")
    local final_name = (type(name) == "string" and name ~= "") and name or ("Bookmark_" .. os.date("%H%M%S"))
    app.setCurrentLayerName(make_layer_name(final_name))
    app.setLayerVisibility(false)

    -- return to the layer that was active before
    local newStruct = app.getDocumentStructure()
    local maxLayer = #(newStruct.pages[structure.currentPage].layers)
    local safeLayer = math.max(1, math.min(activeLayer, maxLayer))
    app.setCurrentLayer(safeLayer)
end

--- create bookmark with a custom name
function new_bookmark(name)
    _create_bookmark_layer(name)
    show_dialog("Bookmark created")
end

--- quick create bookmark (no dialog, auto-generated name)
function new_bookmark_quick()
    _create_bookmark_layer("")
end

function delete_layer(page, layerID)
    local structure = app.getDocumentStructure()
    if page < 1 or page > #structure.pages then
        return
    end

    local layers = structure.pages[page].layers
    if layerID < 1 or layerID > #layers then
        return
    end

    app.setCurrentPage(page)
    app.setCurrentLayer(layerID)
    app.layerAction("ACTION_DELETE_LAYER")
    app.setCurrentLayer(1)
end

--- mode = 1  → next bookmark
--- mode = -1 → previous bookmark
function search_bookmark(mode)
    local bookmarks = get_bookmarks()
    if #bookmarks == 0 then
        return
    end

    local currentPage = app.getDocumentStructure().currentPage
    local target = nil

    if mode == 1 then
        -- next: first bookmark strictly after current page
        for _, bm in ipairs(bookmarks) do
            if bm.page > currentPage then
                target = bm;
                break
            end
        end
        target = target or bookmarks[1] -- wrap around
    else
        -- previous: last bookmark strictly before current page
        for i = #bookmarks, 1, -1 do
            if bookmarks[i].page < currentPage then
                target = bookmarks[i];
                break
            end
        end
        target = target or bookmarks[#bookmarks] -- wrap around
    end

    if target then
        app.setCurrentPage(target.page)
        app.scrollToPage(target.page)
    end
end

function search_bookmark_next()
    search_bookmark(1)
end
function search_bookmark_prev()
    search_bookmark(-1)
end

-- list builder
function build_hierarchical_list(bookmarks)
    local tree = {}

    for _, bm in ipairs(bookmarks) do
        local parts = {}
        for part in bm.display_name:gmatch("([^/]+)") do
            table.insert(parts, part)
        end

        local current = tree
        for i, part in ipairs(parts) do
            if not current[part] then
                current[part] = {
                    children = {},
                    bookmark = nil,
                    full_path = table.concat(parts, "/", 1, i),
                    first_page = bm.page
                }
            end
            if i == #parts then
                current[part].bookmark = bm
                current[part].full_path = bm.display_name
            end
            if bm.page < current[part].first_page then
                current[part].first_page = bm.page
            end
            current = current[part].children
        end
    end

    local flat_list = {}

    local function traverse(node, indent)
        local keys = {}
        for k in pairs(node) do
            table.insert(keys, k)
        end

        table.sort(keys, function(a, b)
            if node[a].first_page == node[b].first_page then
                return a < b
            end
            return node[a].first_page < node[b].first_page
        end)

        for _, name in ipairs(keys) do
            local data = node[name]
            local prefix = string.rep("  ", indent)

            if data.bookmark then
                table.insert(flat_list, {
                    id = data.bookmark.page .. "_" .. data.bookmark.layerID,
                    page = data.bookmark.page,
                    display = prefix .. name,
                    bookmark = data.bookmark
                })
            else
                table.insert(flat_list, {
                    id = FOLDER_ID_PREFIX .. data.full_path,
                    page = data.first_page,
                    display = prefix .. "<i>" .. name .. "</i>",
                    bookmark = nil
                })
            end

            traverse(data.children, indent + 1)
        end
    end

    traverse(tree, 0)
    return flat_list
end

--  dialogs

function dialog_new_bookmark()
    local out, code = run_yad('yad --entry --title="New Bookmark" --text="Name (use / for hierarchy):"')
    if code == YAD_OK and out and out ~= "" then
        _create_bookmark_layer(out)
        show_dialog("Bookmark created")
    end
end

function view_bookmarks()
    local bookmarks = get_bookmarks()
    if #bookmarks == 0 then
        show_dialog("No bookmarks found.")
        return
    end

    local flat_list = build_hierarchical_list(bookmarks)
    local cmd = 'yad --list --title="Bookmark Manager" --width=800 --height=550' ..
                    ' --column="ID:HD" --column="Page" --column="Name"'

    for _, item in ipairs(flat_list) do
        cmd = cmd ..
                  string.format(" %s %s %s", bash_escape(item.id), bash_escape(tostring(item.page)),
                bash_escape(item.display))
    end

    cmd = cmd .. ' --button="Jump To:0" --button="Edit:2" --button="Delete:3" --button="Close:1"'

    local out, code = run_yad(cmd)
    if not out or out == "" then
        return
    end

    local selected_id = out:match("^([^|]+)|")
    if not selected_id or selected_id:sub(1, #FOLDER_ID_PREFIX) == FOLDER_ID_PREFIX then
        return
    end

    local page_str, layer_str = selected_id:match("(%d+)_(%d+)")
    local oldPage, oldLayerID = tonumber(page_str), tonumber(layer_str)

    local selected = nil
    for _, bm in ipairs(bookmarks) do
        if bm.page == oldPage and bm.layerID == oldLayerID then
            selected = bm;
            break
        end
    end
    if not selected then
        return
    end

    -- jump
    if code == YAD_OK then
        app.setCurrentPage(selected.page)
        app.scrollToPage(selected.page)

        -- edit
    elseif code == YAD_EDIT then
        local form_cmd = string.format('yad --form --title="Edit Bookmark"' .. ' --field="Page:NUM" "%d..%d..1"' ..
                                           ' --field="Name" %s', selected.page, #app.getDocumentStructure().pages,
            bash_escape(selected.display_name))

        local res, fcode = run_yad(form_cmd)
        if fcode == YAD_OK and res then
            local p_str, n_str = res:match("([^|]*)|([^|]*)")
            local newPage = tonumber(p_str)
            if newPage and n_str and n_str ~= "" then
                if newPage == selected.page then
                    -- rename in place
                    local numLayers = #(app.getDocumentStructure().pages[selected.page].layers)
                    if selected.layerID <= numLayers then
                        app.setCurrentPage(selected.page)
                        local oldCurrent = app.getDocumentStructure().pages[selected.page].currentLayer
                        app.setCurrentLayer(selected.layerID)
                        app.setCurrentLayerName(make_layer_name(n_str))
                        app.setCurrentLayer(math.max(1, math.min(oldCurrent, numLayers)))
                    end
                else
                    -- move: delete old, create on new page
                    delete_layer(selected.page, selected.layerID)
                    app.setCurrentPage(newPage)
                    _create_bookmark_layer(n_str)
                end
            end
        end

        -- delete
    elseif code == YAD_DELETE then
        local _, conf = run_yad('yad --question --text="Delete bookmark ' .. bash_escape(selected.display_name) .. '?"')
        if conf == YAD_OK then
            delete_layer(selected.page, selected.layerID)
        end
    end
end

--  JSON export / import
function export_bookmarks_to_file()
    local bookmarks = get_bookmarks()
    if #bookmarks == 0 then
        show_dialog("No bookmarks to export.")
        return
    end

    local filename, code = run_yad(
        'yad --file --save --confirm-overwrite --title="Export Bookmarks"' .. ' --filename=' ..
            bash_escape(os.tmpname() .. "_bookmarks.json"))
    if code ~= YAD_OK or not filename then
        return
    end
    filename = filename:match("^([^\n|]+)")

    local file = io.open(filename, "w")
    if not file then
        show_dialog("Could not write file: " .. filename)
        return
    end

    file:write('{\n  "version": "1.0",\n  "bookmarks": [\n')
    for i, bm in ipairs(bookmarks) do
        file:write(string.format('    {"page": %d, "name": %s}%s\n', bm.page, json_escape(bm.display_name),
            i < #bookmarks and "," or ""))
    end
    file:write('  ]\n}\n')
    file:close()

    show_dialog("Exported " .. #bookmarks .. " bookmark(s) to:\n" .. filename)
end

--- JSON parser: handles {"page": N, "name": "..."} entries
function parse_bookmarks_json(content)
    local results = {}
    -- iterate over each {...} block
    for block in content:gmatch("{([^}]+)}") do
        local page_str = block:match('"page"%s*:%s*(%d+)')
        -- manage escaped quotes
        local name_str = block:match('"name"%s*:%s*"(.-[^\\])"') or block:match('"name"%s*:%s*""') -- if empty name
        if page_str and name_str then
            -- unescape \" inside the name
            name_str = name_str:gsub('\\"', '"')
            table.insert(results, {
                page = tonumber(page_str),
                name = name_str
            })
        end
    end
    return results
end

function import_bookmarks_from_file()
    local filename, code = run_yad('yad --file --title="Import Bookmarks"')
    if code ~= YAD_OK or not filename then
        return
    end
    filename = filename:match("^([^\n|]+)")

    local file = io.open(filename, "r")
    if not file then
        show_dialog("Could not open file: " .. filename)
        return
    end
    local content = file:read("*all")
    file:close()

    local entries = parse_bookmarks_json(content)
    local numPages = #app.getDocumentStructure().pages
    local imported = 0

    for _, entry in ipairs(entries) do
        if entry.page >= 1 and entry.page <= numPages then
            app.setCurrentPage(entry.page)
            _create_bookmark_layer(entry.name)
            imported = imported + 1
        end
    end

    show_dialog("Imported " .. imported .. " bookmark(s).")
end

function export_import_bookmarks()
    local out, code = run_yad('yad --list --title="Import / Export" --width=300 --height=200' ..
                                  ' --column="Action" "Export Bookmarks" "Import Bookmarks"' ..
                                  ' --button="OK:0" --button="Cancel:1"')
    if code ~= YAD_OK or not out then
        return
    end

    local action = out:match("^([^\n|]+)")
    if action == "Export Bookmarks" then
        export_bookmarks_to_file()
    elseif action == "Import Bookmarks" then
        import_bookmarks_from_file()
    end
end

--  PDF export with bookmarks
function export()
    -- pdftk check
    local pdftk_check, _ = run_yad("which pdftk 2>/dev/null")
    if not pdftk_check or pdftk_check == "" then
        show_dialog("pdftk not found.\nPlease install pdftk to use PDF export.")
        return
    end

    local structure = app.getDocumentStructure()
    local bookmarks = get_bookmarks()

    local defaultName = DEFAULT_EXPORT_PATH
    if structure.xoppFilename and structure.xoppFilename ~= "" then
        defaultName = structure.xoppFilename:match("(.+)%..+$") or DEFAULT_EXPORT_PATH
    end

    local path = app.saveAs(defaultName .. "_export.pdf")
    if not path then
        return
    end

    local tempData = os.tmpname()
    if sep == "\\" then
        tempData = tempData:sub(2)
    end
    local tempPdf = tempData .. "_tmp.pdf"

    -- use pcall so temp files are always cleaned up
    local ok, err = pcall(function()
        -- export to a temporary PDF
        app.export({
            outputFile = tempPdf
        })

        -- dump existing PDF metadata
        if not exec_ok("pdftk " .. bash_escape(tempPdf) .. " dump_data output " .. bash_escape(tempData)) then
            error("pdftk dump_data failed")
        end

        -- append bookmarks
        local file = io.open(tempData, "a+")
        if not file then
            error("Cannot open temp metadata file: " .. tempData)
        end

        local written_paths = {}

        for _, bm in ipairs(bookmarks) do
            local parts = {}
            for part in bm.display_name:gmatch("[^/]+") do
                table.insert(parts, part)
            end

            local current_path = ""
            for i, part in ipairs(parts) do
                if i > 1 then
                    current_path = current_path .. "/"
                end
                current_path = current_path .. part

                if not written_paths[current_path] then
                    file:write("BookmarkBegin\n")
                    file:write("BookmarkTitle: " .. utf8_to_html(part) .. "\n")
                    file:write("BookmarkLevel: " .. i .. "\n")
                    -- Intermediate folder nodes point to the page of the leaf bookmark
                    file:write("BookmarkPageNumber: " .. bm.page .. "\n")
                    written_paths[current_path] = true
                end
            end
        end

        file:close()

        -- rebuild PDF with updated metadata
        if not exec_ok("pdftk " .. bash_escape(tempPdf) .. " update_info " .. bash_escape(tempData) .. " output " ..
                           bash_escape(path)) then
            error("pdftk update_info failed")
        end
    end)

    -- clean up temp files
    os.remove(tempData)
    os.remove(tempPdf)

    if ok then
        show_dialog("Exported successfully to:\n" .. path)
    else
        show_dialog("Export failed:\n" .. tostring(err))
    end
end

function initUi()
    app.registerUi({
        menu = "Previous Bookmark",
        toolbarId = "CUSTOM_PREVIOUS_BOOKMARK",
        callback = "search_bookmark_prev",
        iconName = "go-previous"
    })
    app.registerUi({
        menu = "New Bookmark",
        toolbarId = "CUSTOM_NEW_BOOKMARK",
        callback = "dialog_new_bookmark",
        iconName = "bookmark-new-symbolic"
    })
    app.registerUi({
        menu = "New Bookmark (No dialog)",
        toolbarId = "CUSTOM_NEW_BOOKMARK_NO_DIALOG",
        callback = "new_bookmark_quick",
        iconName = "bookmark-new-symbolic"
    })
    app.registerUi({
        menu = "Next Bookmark",
        toolbarId = "CUSTOM_NEXT_BOOKMARK",
        callback = "search_bookmark_next",
        iconName = "go-next"
    })
    app.registerUi({
        menu = "View Bookmarks",
        toolbarId = "CUSTOM_VIEW_BOOKMARKS",
        callback = "view_bookmarks",
        iconName = "user-bookmarks-symbolic"
    })
    app.registerUi({
        menu = "Export to PDF",
        toolbarId = "CUSTOM_EXPORT_WITH_BOOKMARKS",
        callback = "export",
        iconName = "xopp-document-export-pdf"
    })
    app.registerUi({
        menu = "Export / Import",
        toolbarId = "CUSTOM_EXPORT_IMPORT",
        callback = "export_import_bookmarks",
        iconName = "document-save-as"
    })

    sep = package.config:sub(1, 1)
    if sep == "\\" then
        DEFAULT_EXPORT_PATH = "%TEMP%\\temp"
    end
end
