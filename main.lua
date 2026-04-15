utf8_to_html = require("utf8_to_html")

DEFAULT_EXPORT_PATH = "/tmp/temp"
sep = nil

function bash_escape(str)
  if not str then return "''" end
  return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

function json_escape(str)
  if not str then return '""' end
  return '"' .. str:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

function run_yad(cmd)
  local tmp = os.tmpname()
  os.execute(cmd .. ' > ' .. tmp .. ' 2>/dev/null; echo "EXIT:"$? >> ' .. tmp)
  local f = io.open(tmp, "r")
  if not f then return nil, 1 end
  local out, code = "", 1
  for line in f:lines() do
    if line:find("^EXIT:") then 
      code = tonumber(line:match("%d+")) 
    else 
      out = out .. line
    end
  end
  f:close()
  os.remove(tmp)
  if out == "" then return nil, code end
  return out, code
end

function parse_bookmark_name(raw_name)
  return raw_name:sub(11)
end

function make_layer_name(display_name)
  return "Bookmark::" .. display_name
end

function get_bookmarks()
  local structure = app.getDocumentStructure()
  local bookmarks = {}
  
  for page = 1, #structure.pages do
    for layerID, layer in pairs(structure.pages[page].layers) do
      if layer.name:sub(1,10) == "Bookmark::" then
        table.insert(bookmarks, { page = page, layerID = layerID, display_name = parse_bookmark_name(layer.name) })
      end
    end
  end
  
  table.sort(bookmarks, function(a,b)
    if a.page == b.page then return a.display_name < b.display_name end
    return a.page < b.page
  end)
  
  return bookmarks
end

function new_bookmark_silent(name)
  local structure = app.getDocumentStructure()
  local activeLayer = structure.pages[structure.currentPage].currentLayer
  
  app.layerAction("ACTION_NEW_LAYER")
  app.setCurrentLayerName(make_layer_name(type(name) == "string" and name ~= "" and name or ("Bookmark_" .. os.date("%H%M%S"))))
  app.setLayerVisibility(false)
  
  local newStruct = app.getDocumentStructure()
  local maxLayer = #(newStruct.pages[structure.currentPage].layers)
  local safeLayer = math.min(activeLayer, maxLayer)
  if safeLayer < 1 then safeLayer = 1 end
  
  app.setCurrentLayer(safeLayer)
end

function new_bookmark(name)
  new_bookmark_silent(name)
  app.msgbox("Bookmark created", {[1]="OK"})
end

function new_bookmark_quick()
  new_bookmark_silent("")
end

function delete_layer(page, layerID)
  local structure = app.getDocumentStructure()
  if page < 1 or page > #structure.pages then return end
  
  local layers = structure.pages[page].layers
  if layerID < 1 or layerID > #layers then return end
  
  app.setCurrentPage(page)
  app.setCurrentLayer(layerID)
  app.layerAction("ACTION_DELETE_LAYER")
  
  app.setCurrentLayer(1)
end

function search_bookmark(mode)
  local bookmarks = get_bookmarks()
  if #bookmarks == 0 then return end
  
  local currentPage = app.getDocumentStructure().currentPage
  local target = nil
  
  if mode == 1 then
    for _, bm in ipairs(bookmarks) do
      if bm.page > currentPage then target = bm; break end
    end
    target = target or bookmarks[1]
  else
    for i = #bookmarks, 1, -1 do
      if bookmarks[i].page < currentPage then target = bookmarks[i]; break end
    end
    target = target or bookmarks[#bookmarks]
  end
  
  if target then
    app.setCurrentPage(target.page)
    app.scrollToPage(target.page)
  end
end

function dialog_new_bookmark()
  local out, code = run_yad('yad --entry --title="New Bookmark" --text="Name (use / for hierarchy):"')
  if code == 0 and out and out ~= "" then new_bookmark(out) end
end

function build_hierarchical_list(bookmarks)
  local tree = {}
  for _, bm in ipairs(bookmarks) do
    local parts = {}
    for part in string.gmatch(bm.display_name, "([^/]+)") do table.insert(parts, part) end
    local current = tree
    for i, part in ipairs(parts) do
      if not current[part] then current[part] = { children = {}, bookmark = nil, full_path = table.concat(parts, "/", 1, i) } end
      if i == #parts then
        current[part].bookmark = bm
        current[part].full_path = bm.display_name
      end
      current = current[part].children
    end
  end
  
  local flat_list = {}
  local function traverse(node, indent)
    local keys = {}
    for k in pairs(node) do table.insert(keys, k) end
    table.sort(keys)
    
    for _, name in ipairs(keys) do
      local data = node[name]
      local prefix = string.rep("  ", indent)
      if data.bookmark then
        table.insert(flat_list, { id = data.bookmark.page .. "_" .. data.bookmark.layerID, page = data.bookmark.page, display = prefix .. name, bookmark = data.bookmark })
      else
        table.insert(flat_list, { id = "FOLDER_" .. data.full_path, page = "-", display = prefix .. "<i>" .. name .. "</i>", bookmark = nil })
      end
      traverse(data.children, indent + 1)
    end
  end
  traverse(tree, 0)
  return flat_list
end

function view_bookmarks()
  local bookmarks = get_bookmarks()
  if #bookmarks == 0 then return end
  
  local flat_list = build_hierarchical_list(bookmarks)
  local cmd = 'yad --list --title="Bookmark Manager" --width=800 --height=550 --column="ID:HD" --column="Page" --column="Name" '
  
  for _, item in ipairs(flat_list) do
    cmd = cmd .. string.format(" %s %s %s", bash_escape(item.id), bash_escape(tostring(item.page)), bash_escape(item.display))
  end
  
  cmd = cmd .. ' --button="Jump To:0" --button="Edit:2" --button="Delete:3" --button="Close:1"'
  
  local out, code = run_yad(cmd)
  if not out or out == "" then return end
  
  local selected_id = out:match("^([^|]+)|")
  if not selected_id or selected_id:sub(1,6) == "FOLDER" then return end
  
  local page_str, layer_str = selected_id:match("(%d+)_(%d+)")
  local oldPage, oldLayerID = tonumber(page_str), tonumber(layer_str)
  
  local selected = nil
  for _, bm in ipairs(bookmarks) do
    if bm.page == oldPage and bm.layerID == oldLayerID then selected = bm; break end
  end
  if not selected then return end
  
  if code == 0 then
    app.setCurrentPage(selected.page)
    app.scrollToPage(selected.page)
  elseif code == 4 then
    local _, conf = run_yad('yad --question --text="Delete bookmark?"')
    if conf == 0 then delete_layer(selected.page, selected.layerID) end
  elseif code == 2 then
    local form_cmd = string.format('yad --form --title="Edit" --field="Page:NUM" "%d..%d..1" --field="Name" %s', selected.page, #app.getDocumentStructure().pages, bash_escape(selected.display_name))
    local res, fcode = run_yad(form_cmd)
    if fcode == 0 and res then
      local p_str, n_str = res:match("([^|]*)|([^|]*)|")
      local newPage = tonumber(p_str)
      if newPage and n_str and n_str ~= "" then
        if newPage == selected.page then
          local numLayers = #(app.getDocumentStructure().pages[selected.page].layers)
          if selected.layerID <= numLayers then
            app.setCurrentPage(selected.page)
            local oldCurrent = app.getDocumentStructure().pages[selected.page].currentLayer
            app.setCurrentLayer(selected.layerID)
            app.setCurrentLayerName(make_layer_name(n_str))
            
            local safeOld = math.min(oldCurrent, numLayers)
            if safeOld < 1 then safeOld = 1 end
            app.setCurrentLayer(safeOld)
          end
        else
          delete_layer(selected.page, selected.layerID)
          app.setCurrentPage(newPage)
          new_bookmark_silent(n_str)
        end
      end
    end
  elseif code == 3 then
    local res, rcode = run_yad(string.format('yad --entry --title="Rename" --text="New name:" --entry-text=%s', bash_escape(selected.display_name)))
    if rcode == 0 and res and res ~= "" then
      local numLayers = #(app.getDocumentStructure().pages[selected.page].layers)
      if selected.layerID <= numLayers then
        app.setCurrentPage(selected.page)
        local oldCurrent = app.getDocumentStructure().pages[selected.page].currentLayer
        app.setCurrentLayer(selected.layerID)
        app.setCurrentLayerName(make_layer_name(res))
        
        local safeOld = math.min(oldCurrent, numLayers)
        if safeOld < 1 then safeOld = 1 end
        app.setCurrentLayer(safeOld)
      end
    end
  end
end

function export_bookmarks_to_file()
  local bookmarks = get_bookmarks()
  if #bookmarks == 0 then return end
  
  local filename, code = run_yad('yad --file --save --confirm-overwrite --title="Export" --filename=' .. bash_escape(os.tmpname() .. "_bookmarks.json"))
  if code ~= 0 or not filename then return end
  filename = filename:match("^([^|]+)")
  
  local file = io.open(filename, "w")
  if file then
    file:write('{\n  "version": "1.0",\n  "bookmarks": [\n')
    for i, bm in ipairs(bookmarks) do
      file:write(string.format('    {"page": %d, "name": %s}%s\n', bm.page, json_escape(bm.display_name), i < #bookmarks and "," or ""))
    end
    file:write('  ]\n}\n')
    file:close()
  end
end

function import_bookmarks_from_file()
  local filename, code = run_yad('yad --file --title="Import"')
  if code ~= 0 or not filename then return end
  filename = filename:match("^([^|]+)")
  
  local file = io.open(filename, "r")
  if not file then return end
  local content = file:read("*all")
  file:close()
  
  local numPages = #app.getDocumentStructure().pages
  for page_str, name_str in content:gmatch('"page":%s*(%d+),%s*"name":%s*"([^"]+)"') do
    local page = tonumber(page_str)
    if page and page >= 1 and page <= numPages then
      app.setCurrentPage(page)
      new_bookmark_silent(name_str)
    end
  end
end

function export_import_bookmarks()
  local out, code = run_yad('yad --list --title="Import/Export" --width=300 --height=200 --column="Action" "Export Bookmarks" "Import Bookmarks" --button="OK:0" --button="Cancel:1"')
  if code ~= 0 or not out then return end
  local action = out:match("^([^|]+)")
  if action == "Export Bookmarks" then export_bookmarks_to_file()
  elseif action == "Import Bookmarks" then import_bookmarks_from_file() end
end

function export()
  local pdftk_check, _ = run_yad("which pdftk 2>/dev/null")
  if not pdftk_check or pdftk_check == "" then return end
  
  local structure = app.getDocumentStructure()
  local bookmarks = get_bookmarks()
  
  local defaultName = DEFAULT_EXPORT_PATH
  if structure.xoppFilename and structure.xoppFilename ~= "" then
    defaultName = structure.xoppFilename:match("(.+)%..+$")
  end
  local path = app.saveAs(defaultName .. "_export.pdf")
  if not path then return end
  
  local tempData = os.tmpname()
  if sep == "\\" then tempData = tempData:sub(2) end
  local tempPdf = tempData .. "_tmp.pdf"
  
  app.export({outputFile = tempPdf})
  os.execute("pdftk " .. bash_escape(tempPdf) .. " dump_data output " .. bash_escape(tempData))
  
  local file = io.open(tempData, "a+")
  for _, bm in ipairs(bookmarks) do
    local level = select(2, bm.display_name:gsub("/", "")) + 1
    local parts = {}
    for part in bm.display_name:gmatch("[^/]+") do table.insert(parts, part) end
    local short_name = utf8_to_html(parts[#parts] or "Bookmark")
    
    file:write("BookmarkBegin\nBookmarkTitle: " .. short_name .. "\nBookmarkLevel: " .. level .. "\nBookmarkPageNumber: " .. bm.page .. "\n")
  end
  file:close()
  
  os.execute("pdftk " .. bash_escape(tempPdf) .. " update_info " .. bash_escape(tempData) .. " output " .. bash_escape(path))
  os.remove(tempData)
  os.remove(tempPdf)
end

function initUi()
  app.registerUi({menu="Previous Bookmark", toolbarId="CUSTOM_PREVIOUS_BOOKMARK", callback="search_bookmark", mode=-1, iconName="go-previous"})
  app.registerUi({menu="New Bookmark", toolbarId="CUSTOM_NEW_BOOKMARK", callback="dialog_new_bookmark", iconName="bookmark-new-symbolic"})
  app.registerUi({menu="New Bookmark (No dialog)", toolbarId="CUSTOM_NEW_BOOKMARK_NO_DIALOG", callback="new_bookmark_quick", iconName="bookmark-new-symbolic"})
  app.registerUi({menu="Next Bookmark", toolbarId="CUSTOM_NEXT_BOOKMARK", callback="search_bookmark", mode=1, iconName="go-next"})
  app.registerUi({menu="View Bookmarks", toolbarId="CUSTOM_VIEW_BOOKMARKS", callback="view_bookmarks", iconName="user-bookmarks-symbolic"})
  app.registerUi({menu="Export to PDF", toolbarId="CUSTOM_EXPORT_WITH_BOOKMARKS", callback="export", iconName="xopp-document-export-pdf"})
  app.registerUi({menu="Export/Import", toolbarId="CUSTOM_EXPORT_IMPORT", callback="export_import_bookmarks", iconName="document-save-as"})
  
  sep = package.config:sub(1,1)
  if sep == "\\" then DEFAULT_EXPORT_PATH = "%TEMP%\\temp" end
end