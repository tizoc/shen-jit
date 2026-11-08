-- How the guide and the documents rendered with it reach site/template.html. Pandoc has no grammar
-- for Shen, so this marks what the page colours itself: a transcript's prompts and output, and
-- comments. It also gives each document's page its title, and points links at the pages.

-- The documents with a page, and how a link that only names one reads there.
local PAGES = {
  design = 'How Shen/JIT works',
  semantics = 'Shen/JIT semantics',
  bytecode = 'Shen/JIT instructions and frames',
  ffi = 'Calling C',
  buffers = 'Buffers and cursors',
  grammar = 'Grammars over bytes',
  io = 'Chunk I/O',
  fs = 'Filesystem operations',
  ['tree-sitter'] = 'Tree-sitter bindings',
  framing = 'Binary framing',
  ['io-sockets'] = 'Socket I/O endpoints',
  deadlines = 'Operation deadlines',
  ['http-head'] = 'HTTP head framing',
  http = 'HTTP requests and responses',
  ['http-streaming'] = 'Streaming HTTP responses',
  ['http-listener'] = 'Bounded HTTP servers',
  json = 'JSON',
  datalog = 'Datalog',
  curl = 'HTTP clients with libcurl',
}
local REPOSITORY = 'https://github.com/tizoc/shen-jit/blob/main/'

-- A link to a document with a page goes there, and any other into the repository goes to GitHub, as
-- the page is not next to it. A document's own links are relative to docs/, and the guide's are
-- to GitHub, so that each also works where it is read in the repository.
function Link(link)
  local path, fragment = link.target:match('^([^#]*)(#?.*)$')
  if path == '' then return nil end
  if path:sub(1, #REPOSITORY) == REPOSITORY then
    path = path:sub(#REPOSITORY + 1)
  elseif path:match('^%a[%w+.-]*:') then
    return nil
  elseif path:sub(1, 3) == '../' then
    path = path:sub(4)
  else
    path = 'docs/' .. path
  end
  local page = path:match('^docs/([%w-]+)%.md$')
  if page and PAGES[page] then
    link.target = page .. '.html' .. fragment
    local text = pandoc.utils.stringify(link.content)
    if text == page .. '.md' or text == path then
      link.content = { pandoc.Str(PAGES[page]) }
    end
  else
    link.target = REPOSITORY .. path .. fragment
  end
  return link
end

-- A document's first heading is its page's title, as the guide's already is. In the page, the
-- slash in the name is in the logo's colour.
local function with_slash(inlines)
  local out = pandoc.List()
  for _, inline in ipairs(inlines) do
    if inline.t == 'Str' and inline.text == 'Shen/JIT' then
      out:insert(pandoc.Str('Shen'))
      out:insert(pandoc.RawInline('html', '<i>/</i>'))
      out:insert(pandoc.Str('JIT'))
    else
      out:insert(inline)
    end
  end
  return out
end

function Pandoc(doc)
  local first = doc.blocks[1]
  if not doc.meta.title and first and first.t == 'Header' then
    doc.meta.title = pandoc.MetaInlines(first.content)
    doc.blocks:remove(1)
  end
  doc.meta.pagetitle = pandoc.utils.stringify(doc.meta.title)
  doc.meta.title = pandoc.MetaInlines(with_slash(doc.meta.title))
  return doc
end

local function escape(text)
  return (text:gsub('[&<>]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;' }))
end

local function span(class, text)
  return '<span class="' .. class .. '">' .. escape(text) .. '</span>'
end

local function transcript(line)
  local prompt, rest = line:match('^(%(%d+[-+]%))(.*)$')
  if prompt then return span('p', prompt) .. escape(rest) end
  if line == '' then return '' end
  return span('o', line)
end

local function comments(pattern)
  return function(line)
    local code, comment = line:match('^(.-)(' .. pattern .. '.*)$')
    if code then return escape(code) .. span('c', comment) end
    return escape(line)
  end
end

local marks = {
  repl = transcript,
  sh = comments('%f[%S]#'),
  shen = comments('\\\\'),
}

function CodeBlock(block)
  local mark = marks[block.classes[1]] or escape
  local lines = {}
  for line in (block.text .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = mark(line)
  end
  return pandoc.RawBlock('html', '<pre><code>' .. table.concat(lines, '\n') .. '</code></pre>')
end

-- A wide table scrolls by itself, not the page.
function Table(wide)
  return pandoc.Div({ wide }, pandoc.Attr('', { 'wide' }))
end
