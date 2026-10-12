-- Pandoc filter for the packaged HTML documentation.
--
-- Turns GitHub-style alerts into styled boxes:
--
--   > [!WARNING]
--   > Text with **formatting** and `code`.
--
-- Formatting inside the box is kept (unlike converting it to plain text).

local kinds = {
  NOTE      = { "ℹ️", "Note" },
  TIP       = { "💡", "Tip" },
  IMPORTANT = { "❗", "Important" },
  WARNING   = { "⚠️", "Warning" },
  CAUTION   = { "🛑", "Caution" },
}

local function is_break(inline)
  return inline and (inline.t == "SoftBreak" or inline.t == "LineBreak" or inline.t == "Space")
end

function BlockQuote(el)
  local first = el.content[1]
  if not first or (first.t ~= "Para" and first.t ~= "Plain") or #first.content == 0 then
    return nil
  end
  local marker = pandoc.utils.stringify(first.content[1])
  local kind = marker:match("^%[!(%u+)%]$")
  if not kind or not kinds[kind] then
    return nil
  end

  local inlines = first.content
  table.remove(inlines, 1)
  while is_break(inlines[1]) do
    table.remove(inlines, 1)
  end

  local blocks = {}
  if #inlines > 0 then
    table.insert(blocks, pandoc.Para(inlines))
  end
  for i = 2, #el.content do
    table.insert(blocks, el.content[i])
  end

  local icon, label = kinds[kind][1], kinds[kind][2]
  local title = pandoc.Div({ pandoc.Plain({ pandoc.Str(icon .. " " .. label) }) },
    pandoc.Attr("", { "admonition-title" }))
  table.insert(blocks, 1, title)
  return pandoc.Div(blocks, pandoc.Attr("", { "admonition", kind:lower() }))
end

-- Links between the Markdown documents point to the HTML files in the package.
function Link(el)
  if not el.target:match("^%a+://") then
    el.target = el.target:gsub("%.md$", ".html"):gsub("%.md#", ".html#")
  end
  return el
end

-- <!-- release-key --> in the Markdown is replaced with the release key and its
-- fingerprint (set by package.sh), so the documentation always shows the key
-- the package was signed with.
function RawBlock(el)
  if el.format ~= "html" or not el.text:match("release%-key") then
    return nil
  end
  local pem = os.getenv("RC_RELEASE_KEY_PEM")
  local fpr = os.getenv("RC_RELEASE_KEY_FPR")
  if not pem or pem == "" then
    return pandoc.Para({ pandoc.Strong({ pandoc.Str("This package is not signed.") }) })
  end
  return {
    pandoc.Para({ pandoc.Str("Release key fingerprint (SHA-256 of the DER public key):") }),
    pandoc.CodeBlock(fpr),
    pandoc.Para({ pandoc.Str("Release public key:") }),
    pandoc.CodeBlock(pem),
  }
end
