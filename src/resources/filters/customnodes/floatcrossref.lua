-- crossreffloat.lua
-- Copyright (C) 2023 Posit Software, PBC

_quarto.ast.add_handler({

  -- empty table so this handler is only called programmatically
  class_name = {},

  -- the name of the ast node, used as a key in extended ast filter tables
  ast_name = "FloatCrossref",

  -- generic names this custom AST node responds to
  -- this is still unimplemented
  interfaces = {"Crossref"},

  -- float crossrefs are always blocks
  kind = "Block",

  parse = function(div)
    fail("FloatCrossref nodes should not be parsed")
  end,

  slots = { "content", "caption_long", "caption_short" },

  constructor = function(tbl)
    if tbl.attr then
      tbl.identifier = tbl.attr.identifier
      tbl.classes = tbl.attr.classes
      tbl.attributes = as_plain_table(tbl.attr.attributes)
      tbl.attr = nil
    end
    return tbl
  end
})

function cap_location(float)
  local ref = refType(float.identifier)
  local qualified_key = ref .. '-cap-location'
  local result = (
    float.attributes[qualified_key] or
    float.attributes['cap-location'] or
    option_as_string(qualified_key) or
    option_as_string('cap-location') or
    capLocation(ref) or
    crossref.categories.by_ref_type[ref].default_caption_location)

  if result ~= "margin" and result ~= "top" and result ~= "bottom" then
    error("Invalid caption location for float: " .. float.identifier .. 
      " requested " .. result .. 
      ".\nOnly 'top', 'bottom', and 'margin' are supported. Assuming 'bottom'.")
    result = "bottom"
  end
    
  return result
end

local function get_node_from_float_and_type(float, type)
  -- this explicit check appears necessary for the case where
  -- float.content is directly the node we want, and not a container that
  -- contains the node.
  if float.content.t == type then
    return float.content
  else
    local found_node = nil
    float.content:walk({
      traverse = "topdown",
      [type] = function(node)
        found_node = node
        return nil, false -- don't recurse
      end
    })
    return found_node
  end
end

-- default renderer first
_quarto.ast.add_renderer("FloatCrossref", function(_)
  return true
end, function(float)
  return pandoc.Div({
    pandoc.Str("This is a placeholder FloatCrossref")
  })
end)

local function ensure_custom(node)
  if pandoc.utils.type(node) == "Block" or pandoc.utils.type(node) == "Inline" then
    return _quarto.ast.resolve_custom_data(node)
  end
  return node
end

function prepare_caption(float)
  float = ensure_custom(float)
  -- this should never happen, but it appeases the Lua analyzer
  if float == nil then
    return
  end
  local caption_content = float.caption_long.content or float.caption_long

  if float.parent_id then
    prependSubrefNumber(caption_content, float.order)
  else
    local title_prefix = float_title_prefix(float)
    tprepend(caption_content, title_prefix)
  end
  return float
end

-- capture relevant figure attributes then strip them
local function get_figure_attributes(el)
  local align = figAlignAttribute(el)
  local keys = tkeys(el.attr.attributes)
  for _,k in pairs(keys) do
    if isFigAttribute(k) then
      el.attr.attributes[k] = nil
    end
  end
  local figureAttr = {}
  local style = el.attr.attributes["style"]
  if style then
    figureAttr["style"] = style
    el.attributes["style"] = nil
  end
  return {
    align = align,
    figureAttr = figureAttr
  }
end

_quarto.ast.add_renderer("FloatCrossref", function(_)
  return _quarto.format.isLatexOutput()
end, function(float)
  local figEnv = latexFigureEnv(float)
  local figPos = latexFigurePosition(float, figEnv)
  local float_type = refType(float.identifier)
  local capLoc = capLocation(float_type, "bottom")
  local caption_cmd_name = latexCaptionEnv(float)

  if float.parent_id then
    if caption_cmd_name == kSideCaptionEnv then
      fail("Don't know how to make subcaptions for side captions yet")
      return {}
    end
    caption_cmd_name = "subcaption"
  end
  -- FIXME the old code had this bit about kSideCaptionEnv that
  -- we need to handle still
  -- 
  -- markupLatexCaption(divEl, captionInlines, captionEnv)
  -- if captionEnv == kSideCaptionEnv then
  --   if #content > 1 then
  --     content:insert(2, pandoc.Para(captionInlines))
  --   else
  --     content:insert(#content, pandoc.Para(captionInlines))
  --   end
  -- else 
  --   content:insert(pandoc.Para(captionInlines))
  -- end

  local fig_scap = attribute(float, kFigScap, nil)
  if fig_scap then
    fig_scap = pandoc.Span(markdownToInlines(fig_scap))
  end

  local latex_caption

  if float.caption_long then
    local label_cmd = quarto.LatexInlineCommand({
      name = "label",
      arg = pandoc.Str(float.identifier)
    })
    float.caption_long.content:insert(1, label_cmd)
    latex_caption = quarto.LatexInlineCommand({
      name = caption_cmd_name,
      opt_arg = fig_scap,
      arg = pandoc.Span(quarto.utils.as_inlines(float.caption_long) or {}) -- unnecessary to do the "or {}" bit but the Lua analyzer doesn't know that
    })
  end

  local figure_content
  local pt = pandoc.utils.type(float.content)
  if pt == "Block" then
    figure_content = pandoc.Blocks({ float.content })
  elseif pt == "Blocks" then
    figure_content = float.content
  else
    fail("Unexpected type for float content: " .. pt)
    return {}
  end

  -- align the figure
  local align = figAlignAttribute(float)
  if align == "center" then
    figure_content = pandoc.Blocks({
      quarto.LatexBlockCommand({
        name = "centering",
        inside = true,
        arg = figure_content
      })
    })
  elseif align == "right" then
    figure_content:insert(1, quarto.LatexInlineCommand({
      name = "hfill",
    }))
  end -- otherwise, do nothing
  -- figure_content:insert(1, pandoc.RawInline("latex", latexBeginAlign(align)))
  -- figure_content:insert(pandoc.RawInline("latex", latexEndAlign(align)))

  -- insert caption
  if latex_caption then
    if capLoc == "top" then
      figure_content:insert(1, latex_caption)
    else
      figure_content:insert(latex_caption)
    end
  end

  if float.parent_id then
    local width = float.width or "0.50"
    return quarto.LatexEnvironment({
      name = "minipage",
      pos = "[t]{" .. width .. "\\linewidth}",
      content = figure_content
    })
  else
    return quarto.LatexEnvironment({
      name = figEnv,
      pos = figPos,
      content = figure_content
    })
  end
end)

_quarto.ast.add_renderer("FloatCrossref", function(_)
  return _quarto.format.isHtmlOutput()
end, function(float)
  prepare_caption(float)

  ------------------------------------------------------------------------------------
  -- Special handling for listings
  local found_listing = get_node_from_float_and_type(float, "CodeBlock")
  if found_listing then
    found_listing.attr = merge_attrs(found_listing.attr, pandoc.Attr("", float.classes or {}, float.attributes or {}))
    -- FIXME this seems to be necessary for our postprocessor to kick in
    -- check this out later
    found_listing.identifier = float.identifier
  end

  ------------------------------------------------------------------------------------
  
  return float_crossref_render_html_figure(float)
end)

_quarto.ast.add_renderer("FloatCrossref", function(_)
  return _quarto.format.isDocxOutput() or _quarto.format.isOdtOutput()
end, function(float)
  -- docx format requires us to annotate the caption prefix explicitly
  prepare_caption(float)

  -- options
  local options = {
    pageWidth = wpPageWidth(),
  }

  -- determine divCaption handler (always left-align)
  local divCaption = nil
  if _quarto.format.isDocxOutput() then
    divCaption = docxDivCaption
  elseif _quarto.format.isOdtOutput() then
    divCaption = odtDivCaption
  else
    internal_error()
    return
  end

  options.divCaption = function(el, align) return divCaption(el, "left") end

  -- get alignment
  local align = align_attribute(float)
  
  -- create the row/cell for the figure
  local row = pandoc.List()
  local cell = pandoc.Div({})
  cell.attr = pandoc.Attr(float.identifier, float.classes or {}, float.attributes or {})
  local c = float.content.content or float.content
  if pandoc.utils.type(c) == "Block" then
    cell.content:insert(c)
  elseif pandoc.utils.type(c) == "Blocks" then
    cell.content = c
  end

  transfer_float_image_width_to_cell(float, cell)
  row:insert(cell)

  -- handle caption
  local new_caption = options.divCaption(float.caption_long, align)
  local caption_location = cap_location(float)
  if caption_location == 'top' then
    cell.content:insert(1, new_caption)
  else
    cell.content:insert(new_caption)
  end

  -- content fixups for docx, based on old docx.lua code
  cell = _quarto.ast.walk(cell, {
    Image = function(image)
      if options.pageWidth then
        local layoutPercent = horizontalLayoutPercent(cell)
        if layoutPercent then
          local inches = (layoutPercent/100) * options.pageWidth
          image.attr.attributes["width"] = string.format("%2.2f", inches) .. "in"
          return image
        end
      end
    end,
    Table = function(tbl)
      if align == "center" then
        -- force widths to occupy 100%
        layoutEnsureFullTableWidth(tbl)
        return tbl
      end
    end
  }) or pandoc.Div({}) -- not necessary but the lua analyzer doesn't know that

  -- make the table
  local figureTable = pandoc.SimpleTable(
    pandoc.List(), -- caption
    { layoutTableAlign(align) },  
    {   1   },         -- full width
    pandoc.List(), -- no headers
    { row }            -- figure
  )
  
  -- return it
  return pandoc.utils.from_simple_table(figureTable)
end)

local figcaption_uuid = "0ceaefa1-69ba-4598-a22c-09a6ac19f8ca"

local function create_figcaption(float)
  -- use a uuid to ensure that the figcaption ids won't conflict with real
  -- ids in the document
  local caption_id = float.identifier .. "-caption-" .. figcaption_uuid
  local classes = { float.type:lower() }
  if float.parent_id then
    table.insert(classes, "quarto-subfloat-caption")
  else
    table.insert(classes, "quarto-float-caption")
  end
  return quarto.HtmlTag({
    name = "figcaption",
    attr = pandoc.Attr(caption_id, classes, {}),
    content = float.caption_long,
  }), caption_id
end

function float_crossref_render_html_figure(float)
  float = ensure_custom(float)
  if float == nil then
    fail("Should never happen")
    return pandoc.Div({})
  end

  local caption_content, caption_id = create_figcaption(float)
  local caption_location = cap_location(float)

  local float_content = pandoc.Div(_quarto.ast.walk(float.content, {
    -- strip image captions
    Image = function(image)
      image.caption = {}
      return image
    end
  }) or pandoc.Div({})) -- this should never happen but the lua analyzer doesn't know it
  float_content.attributes["aria-describedby"] = caption_id

  -- otherwise, we render the float as a div with the caption
  local div = pandoc.Div({})

  local found_image = get_node_from_float_and_type(float, "Image") or pandoc.Div({})
  local figure_attrs = get_figure_attributes(found_image)
  
  div.attr = merge_attrs(
    pandoc.Attr(float.identifier, float.classes or {}, float.attributes or {}),
    pandoc.Attr("", {}, figure_attrs.figureAttr))
  -- FIXME consider making the CSS classes uniform
  if float.type == "Listing" then
    div.attr.classes:insert("listing")
  elseif float.type == "Figure" then
    -- apply standalone figure css
    div.attr.classes:insert("quarto-figure")
    div.attr.classes:insert("quarto-figure-" .. figure_attrs.align)
  else
    -- FIXME work more generally here.
  end

  -- also forward any column or caption classes
  local currentClasses = found_image.attr.classes
  for _,k in pairs(currentClasses) do
    if isCaptionClass(k) or isColumnClass(k) then
      div.attr.classes:insert(k)
    end
  end

  local ref = refType(float.identifier)
  local figure_class = "quarto-float-" .. ref

  -- Notice that we need to insert the figure_div value
  -- into the div, but we need to use figure_tbl
  -- to manipulate the contents of the custom node. 
  --
  -- This is because the figure_div is a pandoc.Div (required to
  -- be inserted into pandoc divs), but figure_tbl is
  -- the lua table with the metatable required to marshal
  -- the inner contents of the custom node.
  --
  -- This is relatively ugly, and another instance
  -- of the impedance mismatch we have in the custom AST
  -- API. 
  -- 
  -- it's possible that the better API is for custom constructors
  -- to always return a Lua object and then have a separate
  -- function to convert that to a pandoc AST node.
  local figure_div, figure_tbl = quarto.HtmlTag({
    name = "figure",
    attr = pandoc.Attr("", {figure_class}, {}),
  })
  
  figure_tbl.content.content:insert(float_content)
  if caption_content ~= nil then
    if caption_location == 'top' then
      figure_tbl.content.content:insert(1, caption_content)
    else
      figure_tbl.content.content:insert(caption_content)
    end
  end
  div.content:insert(figure_div)
  return div
end